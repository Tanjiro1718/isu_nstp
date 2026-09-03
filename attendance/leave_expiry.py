"""
Pending leave requests past their deadline are marked deserted.

Throttled to run at most once every 20 seconds via the file-based cache,
matching the pattern used by presence.py and session_alerts.py.
"""
from django.core.cache import cache
from django.utils import timezone

from .models import GeofenceLeaveRequest

_CACHE_KEY = 'leave_expiry_last_run'
_THROTTLE_SECONDS = 20


def dispatch_due_leave_expirations():
    """
    Mark any approved leave request whose deadline has passed as ``deserted``.

    The student either forgot to return or lost connectivity.  The instructor
    is notified so they can update the attendance record if needed.
    """
    # Throttle: skip if we ran recently.
    last_run = cache.get(_CACHE_KEY)
    now = timezone.now()
    if last_run is not None:
        elapsed = (now - last_run).total_seconds()
        if elapsed < _THROTTLE_SECONDS:
            return

    cache.set(_CACHE_KEY, now, timeout=_THROTTLE_SECONDS * 2)

    expired = GeofenceLeaveRequest.objects.filter(
        status='approved',
        returned_at__isnull=True,
        deadline__lte=now,
    ).select_related('session__instructor', 'student__user')

    for leave in expired:
        leave.status = 'deserted'
        leave.save(update_fields=['status'])

        # Notify the instructor that this student did not return.
        try:
            from .fcm_utils import send_leave_expired
            send_leave_expired(leave)
        except Exception as e:
            print(f"Leave-expired push failed for {leave}: {e}")
