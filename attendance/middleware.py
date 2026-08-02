"""Hooks that piggyback on normal API traffic to do scheduled-ish work."""
from .presence import dispatch_due_presence_checks


class PresenceDispatchMiddleware:
    """
    Runs the presence-check sweep on API requests.

    This is the substitute for a cron job: every time the app talks to the
    server we take the opportunity to send any due pings and expire any ignored
    ones. The sweep itself is throttled internally, so this stays cheap.
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

        return response
