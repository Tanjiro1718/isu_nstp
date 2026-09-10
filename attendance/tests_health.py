"""
The /api/health/ warm-up probe.

Free Render instances sleep after ~15 minutes without traffic and pay a long
cold boot on the next request - which the student's very first register POST
used to eat. The app warms the backend on launch by hitting this endpoint, so
it must stay tiny, auth-free, and DB-free.
"""

from django.test import TestCase
from rest_framework.test import APIClient


class HealthProbeTests(TestCase):
    def setUp(self):
        self.client = APIClient()

    def test_health_returns_ok_without_auth(self):
        response = self.client.get('/api/health/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['status'], 'ok')

    def test_health_response_is_small_and_db_free(self):
        # The probe answers with a fixed tiny body - this is the request the
        # app fires at launch to drag a sleeping instance awake.
        response = self.client.get('/api/health/')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.content, b'{"status":"ok"}')