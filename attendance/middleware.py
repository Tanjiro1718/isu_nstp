"""Hooks that piggyback on normal API traffic to do scheduled-ish work."""
from .presence import dispatch_due_presence_checks
from .session_alerts import dispatch_due_session_alerts
from .leave_expiry import dispatch_due_leave_expirations


class PresenceDispatchMiddleware:
    """
    Runs the scheduled sweeps on API requests.

    This is the substitute for a cron job: every time the app talks to the
    server we take the opportunity to send any due pings, expire any ignored
    ones, fire the reminder / start alerts for scheduled sessions, and mark
    any expired leave requests as deserted.  Each sweep is throttled
    internally, so this stays cheap.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)

        # Only bother for API traffic, and never let this break a real response.
        if request.path.startswith('/api/'):
            try:
                dispatch_due_presence_checks()
            except Exception as e:
                print(f"Presence sweep failed: {e}")

            try:
                dispatch_due_session_alerts()
            except Exception as e:
                print(f"Session alert sweep failed: {e}")

            try:
                dispatch_due_leave_expirations()
            except Exception as e:
                print(f"Leave expiry sweep failed: {e}")

        return response
