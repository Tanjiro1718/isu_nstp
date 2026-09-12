"""
Admin approve / reject of pending student registrations.

Regression coverage for the "reject gets stuck in pending" bug:
  - Rejecting (DELETE /api/users/<id>/) must ALWAYS remove the user from the
    pending list, even when the stored ID-picture cleanup fails. The account
    row is deleted first; the photo is detached so a storage error cannot
    abort the row deletion.
  - Approving (PATCH /api/users/<id>/ {'is_active': true}) must persist the
    active flag immediately, sync `is_approved_by_admin`, and leave the
    pending list.
  - Approve/reject notifications run on background threads and can never
    stall or fail the API response.
"""

from unittest.mock import patch

from django.contrib import admin as dj_admin
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import RequestFactory, TestCase
from rest_framework.test import APIClient

from .models import OTPVerification, PendingApproval, StudentProfile, User

PASSWORD = 'Str0ngPass123'


class UserApprovalTestBase(TestCase):
    def setUp(self):
        self.client = APIClient()

    def _register(self, tag='aprv'):
        email = f'{tag}_stu@isu.edu.ph'
        return self.client.post(
            '/api/register/',
            {
                'username': f'{tag}_stu',
                'email': email,
                'password': PASSWORD,
                'first_name': 'Ana',
                'last_name': 'Cruz',
                'id_number': '21-99999',
                'course': 'CWTS',
                'section': '1A',
                'course_and_section': 'CWTS 1A',
                'accept_terms': 'true',
                'id_picture_front': SimpleUploadedFile(
                    'id.jpg', b'fake-jpeg-bytes', content_type='image/jpeg'
                ),
            },
            format='multipart',
        )

    def _pending_ids(self):
        response = self.client.get('/api/users/?is_active=false')
        self.assertEqual(response.status_code, 200, response.data)
        return [u['id'] for u in response.data]

    def _verify(self, email):
        """Prove the email with the stored OTP, like the app does."""
        code = OTPVerification.objects.get(email=email).code
        return self.client.post(
            '/api/verify-code/',
            {'email': email, 'otp_code': code},
            format='json',
        )


class RejectUserTests(UserApprovalTestBase):
    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_new_registration_appears_in_pending(self, mock_send):
        self.assertEqual(self._register().status_code, 201)

        # An account only becomes pending AFTER the email is verified.
        user = User.objects.get(email='aprv_stu@isu.edu.ph')
        self.assertFalse(user.is_active)
        self.assertNotIn(user.id, self._pending_ids())

        verify = self._verify('aprv_stu@isu.edu.ph')
        self.assertEqual(verify.status_code, 200, verify.data)
        self.assertIn(user.id, self._pending_ids())

    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_unverified_registration_does_not_appear_in_pending(self, mock_send):
        """The whole gate: no OTP verified, no 'pending' entry."""
        self.assertEqual(self._register().status_code, 201)
        user = User.objects.get(email='aprv_stu@isu.edu.ph')
        self.assertFalse(user.is_active)
        self.assertNotIn(user.id, self._pending_ids())

    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_reject_deletes_user_and_removes_from_pending(self, mock_send):
        self.assertEqual(self._register().status_code, 201)
        user = User.objects.get(email='aprv_stu@isu.edu.ph')

        # Mock the notification email so the background thread never reaches
        # a real mail server; mock_send is used (not raised) here.
        response = self.client.delete(f'/api/users/{user.id}/')
        self.assertEqual(response.status_code, 204, response.data)

        self.assertFalse(User.objects.filter(pk=user.id).exists())
        self.assertFalse(StudentProfile.objects.filter(user_id=user.id).exists())
        self.assertNotIn(user.id, self._pending_ids())

    @patch('django.core.files.storage.FileSystemStorage.delete',
           side_effect=OSError('storage is down'))
    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_reject_still_removes_user_when_id_photo_cleanup_fails(
        self, mock_send, mock_storage_delete
    ):
        """The stored photo is detached BEFORE the row is deleted, so even if
        deleting the image file raises, the user is still removed from
        pending. This is the exact failure class of the stuck-reject bug."""
        self.assertEqual(self._register().status_code, 201)
        user = User.objects.get(email='aprv_stu@isu.edu.ph')
        profile = StudentProfile.objects.get(user=user)
        self.assertTrue(profile.id_picture_front.name)

        response = self.client.delete(f'/api/users/{user.id}/')
        self.assertEqual(response.status_code, 204, response.data)

        self.assertFalse(User.objects.filter(pk=user.id).exists())
        self.assertNotIn(user.id, self._pending_ids())

    @patch('attendance.views.EmailMultiAlternatives.send',
           side_effect=ConnectionError('smtp down'))
    def test_reject_succeeds_even_if_notification_mail_fails(self, mock_send):
        """A broken mail server must never block the deletion - the email is
        fire-and-forget on a background thread."""
        self.assertEqual(self._register().status_code, 201)
        user = User.objects.get(email='aprv_stu@isu.edu.ph')

        response = self.client.delete(f'/api/users/{user.id}/')
        self.assertEqual(response.status_code, 204, response.data)
        self.assertFalse(User.objects.filter(pk=user.id).exists())


class ApproveUserTests(UserApprovalTestBase):
    @patch('attendance.views.EmailMultiAlternatives.send', return_value=1)
    def test_approve_activates_syncs_flag_and_leaves_pending(self, mock_send):
        self.assertEqual(self._register().status_code, 201)
        user = User.objects.get(email='aprv_stu@isu.edu.ph')

        response = self.client.patch(
            f'/api/users/{user.id}/',
            {'is_active': True},
            format='json',
        )
        self.assertEqual(response.status_code, 200, response.data)

        user.refresh_from_db()
        self.assertTrue(user.is_active)
        profile = StudentProfile.objects.get(user=user)
        self.assertTrue(profile.is_approved_by_admin)
        self.assertNotIn(user.id, self._pending_ids())
        # Appearing in the active list is the approval signal for the app.
        active = self.client.get('/api/users/?is_active=true')
        self.assertIn(user.id, [u['id'] for u in active.data])

    @patch('attendance.views.EmailMultiAlternatives.send',
           side_effect=ConnectionError('smtp down'))
    def test_approve_persists_state_even_if_notification_mail_fails(
        self, mock_send
    ):
        self.assertEqual(self._register().status_code, 201)
        user = User.objects.get(email='aprv_stu@isu.edu.ph')

        response = self.client.patch(
            f'/api/users/{user.id}/',
            {'is_active': True},
            format='json',
        )
        self.assertEqual(response.status_code, 200, response.data)

        user.refresh_from_db()
        self.assertTrue(user.is_active)
        self.assertNotIn(user.id, self._pending_ids())


class PendingApprovalAdminGateTests(TestCase):
    """The Django admin's Pending Approvals must only show accounts whose
    email was verified - registration stays invisible until the OTP passes."""

    def setUp(self):
        self.client = APIClient()

    def _student(self, username, email, verified, approved, active=False):
        user = User.objects.create(
            username=username,
            email=email,
            first_name='Ana',
            last_name='Cruz',
            is_active=active,
        )
        user.set_password(PASSWORD)
        user.save()
        return StudentProfile.objects.create(
            user=user,
            student_id=f'21-{username}',
            component='CWTS',
            section_code='1A',
            course_and_section='CWTS 1A',
            is_email_verified=verified,
            is_approved_by_admin=approved,
        )

    def test_only_email_verified_accounts_land_in_the_pending_waiting_room(self):
        verified = self._student('vfy', 'vfy@isu.edu.ph', True, False)
        self._student('unvfy', 'unvfy@isu.edu.ph', False, False)
        approved = self._student('apprv', 'apprv@isu.edu.ph', True, True)

        request = RequestFactory().get('/')
        registry = dj_admin.site._registry[PendingApproval]
        pending_ids = list(
            registry.get_queryset(request).values_list('pk', flat=True)
        )

        self.assertIn(verified.pk, pending_ids)
        self.assertNotIn(approved.pk, pending_ids)
        self.assertNotIn(
            StudentProfile.objects.get(user__email='unvfy@isu.edu.ph').pk,
            pending_ids,
        )