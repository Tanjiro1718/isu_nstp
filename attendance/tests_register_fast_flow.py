"""
Fast registration + correct account verification.

Registration must return quickly (the OTP email goes out on a background
thread, not inline), an unverified leftover account must not trap the student
on a resubmit, and the verify-code step must actually stamp the email as
verified (otherwise the approval flow has nothing to act on).
"""

from unittest.mock import patch

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase
from rest_framework.test import APIClient

from .models import OTPVerification, StudentProfile, User

PASSWORD = 'Str0ngPass123'


class RegisterFastFlowTestBase(TestCase):
    def setUp(self):
        self.client = APIClient()

    def _register(
        self,
        email='fast_stu@isu.edu.ph',
        username='fast_stu',
        accept_terms='true',
    ):
        return self.client.post(
            '/api/register/',
            {
                'username': username,
                'email': email,
                'password': PASSWORD,
                'first_name': 'Ana',
                'last_name': 'Cruz',
                'id_number': '21-99999',
                'course': 'CWTS',
                'section': '1A',
                'course_and_section': 'CWTS 1A',
                'accept_terms': accept_terms,
                'id_picture_front': SimpleUploadedFile(
                    'id.jpg', b'fake-jpeg-bytes', content_type='image/jpeg'
                ),
            },
            format='multipart',
        )


class RegisterDispatchesOTPInBackground(RegisterFastFlowTestBase):
    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_register_creates_unverified_account_and_dispatches_email(
        self, mock_send
    ):
        response = self._register()
        self.assertEqual(response.status_code, 201, response.data)

        user = User.objects.get(email='fast_stu@isu.edu.ph')
        self.assertFalse(user.is_active)
        profile = StudentProfile.objects.get(user=user)
        self.assertFalse(profile.is_email_verified)

        # The OTP exists server-side and the mailer was invoked.
        self.assertTrue(OTPVerification.objects.filter(email='fast_stu@isu.edu.ph').exists())
        self.assertEqual(mock_send.call_count, 1)

    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_register_fails_fast_when_email_server_is_down(self, mock_send):
        # Even if SMTP is broken the account stays (student can hit "Resend
        # code") - registration is never rolled back into limbo.
        mock_send.side_effect = ConnectionError('smtp down')
        response = self._register()
        self.assertEqual(response.status_code, 201, response.data)
        self.assertTrue(User.objects.filter(email='fast_stu@isu.edu.ph').exists())


class UnverifiedDuplicateReplacementTests(RegisterFastFlowTestBase):
    def test_unverified_duplicate_is_replaced_not_blocked(self):
        self.assertEqual(self._register().status_code, 201, )
        self.assertEqual(
            User.objects.filter(email='fast_stu@isu.edu.ph').count(), 1
        )

        # Student typos, taps back, resubmits the same email.
        second = self._register()
        self.assertEqual(second.status_code, 201, second.data)
        self.assertEqual(
            User.objects.filter(email='fast_stu@isu.edu.ph').count(), 1
        )
        # The replacement carries the new data - old record is gone.
        user = User.objects.get(email='fast_stu@isu.edu.ph')
        self.assertEqual(StudentProfile.objects.filter(user=user).count(), 1)


class VerifiedDuplicateBlockedTests(RegisterFastFlowTestBase):
    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_verified_email_cannot_be_registered_again(self, mock_send):
        self.assertEqual(self._register().status_code, 201)

        # Verify the OTP -> stamps is_email_verified -> email now "owned".
        code = OTPVerification.objects.get(email='fast_stu@isu.edu.ph').code
        verify = self.client.post(
            '/api/verify-code/',
            {'email': 'fast_stu@isu.edu.ph', 'otp_code': code},
            format='json',
        )
        self.assertEqual(verify.status_code, 200, verify.data)

        profile = StudentProfile.objects.get(
            user=User.objects.get(email='fast_stu@isu.edu.ph')
        )
        self.assertTrue(profile.is_email_verified)

        blocked = self._register()
        self.assertEqual(blocked.status_code, 400)
        self.assertIn('already exists', blocked.data['detail'])

    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_verify_otp_stamps_email_verified(self, mock_send):
        self.assertEqual(self._register().status_code, 201)
        code = OTPVerification.objects.get(email='fast_stu@isu.edu.ph').code

        response = self.client.post(
            '/api/verify-code/',
            {'email': 'fast_stu@isu.edu.ph', 'otp_code': code},
            format='json',
        )
        self.assertEqual(response.status_code, 200, response.data)

        user = User.objects.get(email='fast_stu@isu.edu.ph')
        self.assertTrue(StudentProfile.objects.get(user=user).is_email_verified)
        # The code is single-use.
        self.assertFalse(OTPVerification.objects.filter(email='fast_stu@isu.edu.ph').exists())


class ResendVerificationCodeTests(RegisterFastFlowTestBase):
    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_resend_regenerates_and_emails_a_new_code(self, mock_send):
        self.assertEqual(self._register().status_code, 201)
        first_code = OTPVerification.objects.get(email='fast_stu@isu.edu.ph').code

        response = self.client.post(
            '/api/register/resend-code/',
            {'email': 'fast_stu@isu.edu.ph'},
            format='json',
        )
        self.assertEqual(response.status_code, 200, response.data)

        new_code = OTPVerification.objects.get(email='fast_stu@isu.edu.ph').code
        self.assertNotEqual(first_code, new_code)
        self.assertTrue(StudentProfile.objects.get(
            user=User.objects.get(email='fast_stu@isu.edu.ph')
        ))
        self.assertEqual(mock_send.call_count, 2)

    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_resend_rejects_verified_email(self, mock_send):
        self.assertEqual(self._register().status_code, 201)
        code = OTPVerification.objects.get(email='fast_stu@isu.edu.ph').code
        self.client.post(
            '/api/verify-code/',
            {'email': 'fast_stu@isu.edu.ph', 'otp_code': code},
            format='json',
        )

        response = self.client.post(
            '/api/register/resend-code/',
            {'email': 'fast_stu@isu.edu.ph'},
            format='json',
        )
        self.assertEqual(response.status_code, 400)

    def test_resend_returns_404_for_unknown_email(self):
        response = self.client.post(
            '/api/register/resend-code/',
            {'email': 'ghost@isu.edu.ph'},
            format='json',
        )
        self.assertEqual(response.status_code, 404)


ADMIN_NOTIFY = 'attendance.views.send_new_registration_pending'


def _wait_until(predicate, timeout=1.0, interval=0.005):
    """Daemon notification threads race tests; poll until the mock fires."""
    import time

    elapsed = 0.0
    while elapsed < timeout:
        if predicate():
            return True
        time.sleep(interval)
        elapsed += interval
    return False


class AdminPendingNotificationTests(RegisterFastFlowTestBase):
    """Admins get a push the moment an account becomes truly pending, i.e.
    only after the student verifies their email and exactly once."""

    def _verify(self, email='fast_stu@isu.edu.ph'):
        code = OTPVerification.objects.get(email=email).code
        return self.client.post(
            '/api/verify-code/',
            {'email': email, 'otp_code': code},
            format='json',
        )

    @patch(ADMIN_NOTIFY)
    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_verify_code_dispatches_admin_push_once(self, mock_email, mock_notify):
        self.assertEqual(self._register().status_code, 201)

        response = self._verify()
        self.assertEqual(response.status_code, 200, response.data)

        self.assertTrue(_wait_until(lambda: mock_notify.called))
        mock_notify.assert_called_once_with('fast_stu', 'fast_stu@isu.edu.ph')

    @patch(ADMIN_NOTIFY)
    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_registration_alone_does_not_notify_admins(self, mock_email, mock_notify):
        self.assertEqual(self._register().status_code, 201)
        # The account is only saved now; nothing should have fired yet.
        self.assertFalse(_wait_until(lambda: mock_notify.called, timeout=0.2))

    @patch(ADMIN_NOTIFY)
    def test_re_verifying_an_owned_email_does_not_notify_again(self, mock_notify):
        # Simulate an email that was verified earlier (e.g. a stale OTP retry).
        user = User.objects.create(
            email='owned@isu.edu.ph',
            username='owned_stu',
            first_name='Own',
            last_name='Er',
            is_active=False,
        )
        user.set_password(PASSWORD)
        user.save()
        StudentProfile.objects.create(
            user=user,
            student_id='22-11111',
            component='ROTC',
            section_code='1B',
            course_and_section='ROTC 1B',
            is_email_verified=True,
        )
        OTPVerification.objects.create(email='owned@isu.edu.ph', code='000000')

        response = self.client.post(
            '/api/verify-code/',
            {'email': 'owned@isu.edu.ph', 'otp_code': '000000'},
            format='json',
        )
        self.assertEqual(response.status_code, 200, response.data)
        self.assertFalse(_wait_until(lambda: mock_notify.called, timeout=0.2))