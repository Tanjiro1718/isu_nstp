"""
Lazy dispatcher for scheduled attendance sessions.

An instructor schedules an activity for a future `date_time` and picks a
`reminder_minutes` lead. Two things then have to happen without anyone pressing
a button:

  1. At `date_time - reminder_minutes`, the class is told it is about to start.
  2. At `date_time`, the session opens and the class is told to time in.

Like `presence.py`, there is no Celery or cron here, so the sweep runs
opportunistically off normal API traffic (see PresenceDispatchMiddleware). The
consequence is worth stating plainly: on a completely idle server an alert is
sent late, at the moment the next request arrives. Both notifications therefore
quote the real clock time rather than only a countdown, so a late delivery is
still accurate. Each alert is stamped once and never repeats.
"""
import datetime

from django.core.cache import cache
from django.db import transaction
from django.utils import timezone

from .models import AttendanceSession
from .fcm_utils import notify_session_reminder, notify_session_started

# Don't sweep on literally every request.
_SWEEP_CACHE_KEY = 'session_alerts_last_sweep'
_SWEEP_INTERVAL_SECONDS = 20

# How far back we are willing to fire a missed alert. Past this the moment has
# gone: nobody wants a "starts in 5 minutes" buzz for an activity that began
# hours ago, which is what would happen the first time a dormant server wakes.
_STALE_AFTER_MINUTES = 60


def dispatch_due_session_alerts(force=False):
    """
    Send any reminder / start notifications that have come due.

    Returns a small summary dict, handy for tests and manual runs.
    """
    if not force:
        if cache.get(_SWEEP_CACHE_KEY):
            return {'skipped': True, 'reminders': 0, 'starts': 0}
        cache.set(_SWEEP_CACHE_KEY, True, _SWEEP_INTERVAL_SECONDS)

    now = timezone.now()
    return {
        'skipped': False,
        'reminders': _send_due_reminders(now),
        'starts': _send_due_starts(now),
    }


def _send_due_reminders(now):
    """The 'starts in N minutes' heads-up."""
    cutoff = now - datetime.timedelta(minutes=_STALE_AFTER_MINUTES)

    candidates = AttendanceSession.objects.filter(
        reminder_sent_at__isnull=True,
        class_group__isnull=False,
        # Not started yet: once it is open the reminder is pointless, the
        # 'now open' push below is the right message.
        date_time__gt=now,
        date_time__gte=cutoff,
    ).select_related('class_group')

    sent = 0
    for session in candidates:
        if now < session.reminder_at:
            continue  # Lead time hasn't been reached.
        if _claim(session, 'reminder_sent_at', now):
            notify_session_reminder(session)
            sent += 1

    return sent


def _send_due_starts(now):
    """The 'attendance is now open' push at the scheduled start time."""
    cutoff = now - datetime.timedelta(minutes=_STALE_AFTER_MINUTES)

    candidates = AttendanceSession.objects.filter(
        start_notified_at__isnull=True,
        class_group__isnull=False,
        date_time__lte=now,
        date_time__gte=cutoff,
    ).select_related('class_group')

    sent = 0
    for session in candidates:
        if _claim(session, 'start_notified_at', now):
            notify_session_started(session)
            sent += 1

    return sent


def _claim(session, field, now):
    """
    Stamp `field` exactly once, even with two sweeps running at the same time.

    Returns True only for the caller that won the race, so a class can never be
    notified twice for the same event.
    """
    with transaction.atomic():
        locked = (
            AttendanceSession.objects.select_for_update()
            .filter(pk=session.pk, **{f'{field}__isnull': True})
            .first()
        )
        if locked is None:
            return False
        setattr(locked, field, now)
        locked.save(update_fields=[field])
    return True
