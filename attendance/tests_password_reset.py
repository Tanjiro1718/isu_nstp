"""
Forgot-password flow: request a code, then confirm it.

Regression guard for the bug where the request-code endpoint returned a 500
(HTML, not JSON) *after* the code had already been emailed. The delivery
thread writes a (push_sent, email_sent) pair into the caller's container, and
the view unpacks that pair - they must agree on the shape.
"""

from unittest.mock import patch

from django.test import TestCase
from rest_framework.test import APIClient

from .models import PasswordResetCode, User
from .views import _deliver_password_reset_code


class PasswordResetFlowTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='reset_user',
            password='OldPass123',
            email='reset_user@isu.edu.ph',
            role='student',
        )

    # ------------------------------------------------------------------
    # Producer: the container holds the pair as its first element
    # ------------------------------------------------------------------

    def test_delivery_container_holds_the_pair_as_first_element(self):
        container = []

        with patch('attendance.views.EmailMultiAlternatives') as mock_email:
            mock_email.return_value.send.return_value = 1
            _deliver_password_reset_code(self.user, '123456', container)

        # The view does `push_sent, email_sent = container[0]`, so container[0]
        # must be an unpackable pair - not a bare bool.
        self.assertEqual(len(container), 1)
        push_sent, email_sent = container[0]
        self.assertIsInstance(push_sent, bool)
        self.assertIsInstance(email_sent, bool)

    # ------------------------------------------------------------------
    # Request code
    # ------------------------------------------------------------------

    def test_request_code_returns_flags_when_delivery_finishes_quickly(self):
        def fake_deliver(user, code, result_container=None):
            if result_container is not None:
                result_container[:] = [(True, False)]

        with patch(
            'attendance.views._deliver_password_reset_code',
            side_effect=fake_deliver,
        ):
            response = self.client.post(
                '/api/password-reset/request-code/',
                {'email': 'reset_user@isu.edu.ph'},
                format='json',
            )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertTrue(response.data['push_sent'])
        self.assertFalse(response.data['email_sent'])

    def test_request_code_for_unknown_email_stays_neutral(self):
        response = self.client.post(
            '/api/password-reset/request-code/',
            {'email': 'nobody@isu.edu.ph'},
            format='json',
        )
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data.get('push_sent', False))

    # ------------------------------------------------------------------
    # Confirm code
    # ------------------------------------------------------------------

    def _confirm(self, code, password='NewPass123'):
        return self.client.post(
            '/api/password-reset/confirm/',
            {
                'email': 'reset_user@isu.edu.ph',
                'code': code,
                'new_password': password,
            },
            format='json',
        )

    def test_confirm_sets_new_password_and_burns_the_code(self):
        PasswordResetCode.objects.create(user=self.user, code='654321')

        response = self._confirm('654321')
        self.assertEqual(response.status_code, 200, response.data)

        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password('NewPass123'))
        self.assertFalse(PasswordResetCode.objects.filter(user=self.user).exists())

    def test_confirm_with_wrong_code_is_a_json_400(self):
        PasswordResetCode.objects.create(user=self.user, code='654321')

        response = self._confirm('111111')
        self.assertEqual(response.status_code, 400)
        self.assertIn('detail', response.data)

        self.user.refresh_from_db()
        self.assertTrue(self.user.check_password('OldPass123'))
