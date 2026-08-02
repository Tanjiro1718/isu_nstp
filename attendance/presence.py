"""
Lazy dispatcher for random presence checks.

There is no Celery/cron in this project, so instead of a background worker we
run `dispatch_due_presence_checks()` opportunistically whenever the API is
touched (see PresenceDispatchMiddleware). Two things happen on each sweep:

  1. Checks whose `scheduled_at` has arrived are pushed to the student's phone.
  2. Checks whose response window has elapsed are marked missed, which issues a
     warning on the first strike and fails the record on the second.

Caveat worth knowing: pings only go out while *someone* is using the app. In
practice students are polling during a session, so the sweep runs often, but a
completely idle server will delay a ping until the next request arrives.
"""
import datetime

from django.core.cache import cache
from django.db import transaction
from django.utils import timezone

from .models import PresenceCheck
from .fcm_utils import (
    send_presence_check,
    send_presence_warning,
    send_presence_failed,
)

# Don't hammer the database on every single request.
_SWEEP_CACHE_KEY = 'presence_last_sweep'
_SWEEP_INTERVAL_SECONDS = 20


def dispatch_due_presence_checks(force=False):
    """
    Send pings that are due and expire the ones that were ignored.

    Returns a small summary dict, handy for tests and manual runs.
    """
    if not force:
        # Throttle: at most one sweep per interval across all requests.
        if cache.get(_SWEEP_CACHE_KEY):
            return {'skipped': True, 'sent': 0, 'missed': 0}
        cache.set(_SWEEP_CACHE_KEY, True, _SWEEP_INTERVAL_SECONDS)

    now = timezone.now()
    sent = _send_due_checks(now)
    missed = _expire_overdue_checks(now)

    return {'skipped': False, 'sent': sent, 'missed': missed}


def _send_due_checks(now):
    """Push every scheduled check whose moment has arrived."""
    due = PresenceCheck.objects.filter(
        status='pending', scheduled_at__lte=now
    ).select_related('record__student', 'record__session')

    sent = 0
    for check in due:
        record = check.record

        # Someone who already failed or checked out gets no further pings.
        if record.presence_status == 'failed' or record.check_out_at is not None:
            check.status = 'missed'
            check.save(update_fields=['status'])
            continue

        window = datetime.timedelta(
            minutes=record.session.presence_response_minutes
        )
        check.sent_at = now
        check.expires_at = now + window
        check.status = 'sent'
        check.save(update_fields=['sent_at', 'expires_at', 'status'])

        if send_presence_check(check):
            sent += 1

    return sent


def _expire_overdue_checks(now):
    """Mark unanswered checks as missed and escalate warning -> failed."""
    overdue = PresenceCheck.objects.filter(
        status='sent', expires_at__lte=now
    ).select_related('record__student', 'record__session')

    missed = 0
    for check in overdue:
        with transaction.atomic():
            # Re-read under lock so two concurrent sweeps can't double count.
            locked = (
                PresenceCheck.objects.select_for_update()
                .filter(pk=check.pk, status='sent')
                .first()
            )
            if locked is None:
                continue

            locked.status = 'missed'
            record = locked.record
            record.missed_checks += 1

            if record.missed_checks >= 2:
                record.presence_status = 'failed'
            else:
                record.presence_status = 'warned'
                locked.was_warning = True

            locked.save(update_fields=['status', 'was_warning'])
            record.save(update_fields=['missed_checks', 'presence_status'])

        missed += 1

        # Notify outside the transaction; a slow FCM call shouldn't hold locks.
        if record.presence_status == 'failed':
            send_presence_failed(record)
        else:
            send_presence_warning(record, locked)

    return missed
