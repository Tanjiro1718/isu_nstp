"""Per-device authorization for student accounts.

A student account is tied to one device id plus a server-issued secret. The
secret is stored only as a Django password hash. Login binds the first device;
later logins and attendance requests must present the same credentials until an
admin resets the binding.

This is a practical anti-sharing layer, not a replacement for full session
authentication: most of this API still identifies users by a client-supplied
``user_id``. The device secret makes casual sharing and direct attendance calls
from another phone fail, but a determined attacker who obtains the secret can
still impersonate the student on the endpoints that trust ``user_id``.
"""

import logging
import secrets

from django.conf import settings
from django.contrib.auth.hashers import check_password, make_password
from django.utils import timezone
from rest_framework.response import Response

from .models import StudentDeviceBinding, User

logger = logging.getLogger(__name__)

DEVICE_SECRET_HEADER = 'X-Device-Secret'
DEVICE_ID_HEADER = 'X-Device-Id'


class DeviceBindingError(Exception):
    """A device is missing or does not match the account's current binding."""

    def __init__(self, code, message, *, status_code=403, binding=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.binding = binding


def enforcement_enabled():
    """Whether attendance endpoints reject unbound devices.

    Defaults to off so an existing installed app keeps working while the new
    build rolls out. Set DEVICE_BINDING_ENFORCED=true once clients are updated.
    """
    return bool(getattr(settings, 'DEVICE_BINDING_ENFORCED', False))


def _request_value(request, key):
    value = None
    try:
        value = request.data.get(key)
    except Exception:
        value = None
    if value in (None, ''):
        value = request.query_params.get(key)
    return str(value).strip() if value not in (None, '') else ''


def _device_id(request):
    value = (
        _request_value(request, 'device_id')
        or str(request.headers.get(DEVICE_ID_HEADER) or '').strip()
    )
    return str(value or '').strip()[:128]


def _device_secret(request):
    value = (
        _request_value(request, 'device_secret')
        or str(request.headers.get(DEVICE_SECRET_HEADER) or '').strip()
    )
    return str(value or '').strip()


def _text(value, limit):
    return str(value or '').strip()[:limit]


def _client_ip(request):
    forwarded = str(request.META.get('HTTP_X_FORWARDED_FOR') or '').strip()
    if forwarded:
        return forwarded.split(',')[0].strip()
    return request.META.get('REMOTE_ADDR') or None


def _student(user_id):
    try:
        user = User.objects.filter(pk=user_id).first()
    except (TypeError, ValueError):
        return None
    if user is None or str(getattr(user, 'role', '')).lower() != 'student':
        return None
    return user


def binding_summary(binding):
    if binding is None:
        return None
    return {
        'label': binding.device_label or binding.platform or 'Unknown device',
        'platform': binding.platform or '',
        'app_version': binding.app_version or '',
        'bound_at': binding.bound_at.isoformat() if binding.bound_at else None,
        'last_seen_at': (
            binding.last_seen_at.isoformat() if binding.last_seen_at else None
        ),
        'device_code': binding.device_id[-8:].upper(),
    }


def device_error_response(exc):
    if not isinstance(exc, DeviceBindingError):
        raise exc
    return Response(
        {
            'code': exc.code,
            'message': exc.message,
            'bound_device': binding_summary(exc.binding),
        },
        status=exc.status_code,
    )


def _mismatch_error(binding):
    return DeviceBindingError(
        'device_mismatch',
        'This account is already bound to another device. '
        'Contact your NSTP admin to reset it.',
        binding=binding,
    )


def _auth_error(binding):
    return DeviceBindingError(
        'device_auth_failed',
        'This device is no longer authorized for this account. '
        'Contact your NSTP admin to reset it.',
        binding=binding,
    )


def _touch(binding, request, device_label='', platform='', app_version=''):
    fields = ['last_seen_at', 'last_ip']
    binding.last_seen_at = timezone.now()
    binding.last_ip = _client_ip(request)
    if device_label:
        binding.device_label = device_label[:200]
        fields.append('device_label')
    if platform:
        binding.platform = platform[:32]
        fields.append('platform')
    if app_version:
        binding.app_version = app_version[:32]
        fields.append('app_version')
    binding.save(update_fields=fields)


def bind_on_login(request, user):
    """Bind a student's first device, or verify the current one.

    Returns ``(binding, plaintext_secret, created)``. Staff accounts return
    ``(None, None, False)`` and are never bound.
    """
    if user is None or str(getattr(user, 'role', '')).lower() != 'student':
        return None, None, False

    device_id = _device_id(request)
    supplied_secret = _device_secret(request)
    device_label = _text(_request_value(request, 'device_label'), 200)
    platform = _text(_request_value(request, 'platform'), 32)
    app_version = _text(_request_value(request, 'app_version'), 32)

    binding = StudentDeviceBinding.objects.filter(user=user).first()

    if binding is not None:
        if not device_id or binding.device_id != device_id:
            raise _mismatch_error(binding)
        if not supplied_secret or not check_password(
            supplied_secret, binding.secret_hash
        ):
            raise _auth_error(binding)
        _touch(
            binding,
            request,
            device_label=device_label,
            platform=platform,
            app_version=app_version,
        )
        return binding, None, False

    # Legacy clients do not send a device id. Let them log in during rollout;
    # the first login from an updated build creates the binding.
    if not device_id:
        return None, None, False

    plaintext_secret = secrets.token_urlsafe(32)
    binding = StudentDeviceBinding.objects.create(
        user=user,
        device_id=device_id,
        secret_hash=make_password(plaintext_secret),
        device_label=device_label,
        platform=platform,
        app_version=app_version,
        last_ip=_client_ip(request),
    )
    logger.info(
        'Bound student %s to device %s (%s)',
        user.username,
        device_id[-8:],
        device_label or platform or 'unknown',
    )
    return binding, plaintext_secret, True


def validate_session_device(request, user_id):
    """Check the saved session still owns the account's bound device."""
    user = _student(user_id)
    if user is None:
        return None

    binding = StudentDeviceBinding.objects.filter(user=user).first()
    if binding is None:
        raise DeviceBindingError(
            'device_not_bound',
            'This account has no authorized device yet. Please sign in again.',
        )

    device_id = _device_id(request)
    supplied_secret = _device_secret(request)
    if not device_id or binding.device_id != device_id:
        raise _mismatch_error(binding)
    if not supplied_secret or not check_password(
        supplied_secret, binding.secret_hash
    ):
        raise _auth_error(binding)

    _touch(binding, request)
    return binding


def require_bound_device(request, student_id):
    """Raise unless the request comes from the student's bound device.

    During rollout (DEVICE_BINDING_ENFORCED=false) this is a no-op, so older
    installed builds keep working. Only student accounts are checked.
    """
    if not enforcement_enabled():
        return None

    user = _student(student_id)
    if user is None:
        return None

    binding = StudentDeviceBinding.objects.filter(user=user).first()
    if binding is None:
        raise DeviceBindingError(
            'device_not_bound',
            'This account has no authorized device yet. Please sign in again.',
        )

    device_id = _device_id(request)
    supplied_secret = _device_secret(request)
    if not device_id or binding.device_id != device_id:
        raise _mismatch_error(binding)
    if not supplied_secret or not check_password(
        supplied_secret, binding.secret_hash
    ):
        raise _auth_error(binding)

    _touch(binding, request)
    return binding


def reset_binding(user):
    """Remove the current binding so the next login can claim a new device."""
    deleted, _ = StudentDeviceBinding.objects.filter(user=user).delete()
    return bool(deleted)
