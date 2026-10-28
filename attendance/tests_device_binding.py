"""Student account device binding.

A student account is locked to the first device that logs in. Another device is
rejected until an admin resets the binding. Staff accounts are never bound.
"""

from django.test import TestCase, override_settings
from rest_framework.test import APIClient

from .models import StudentDeviceBinding, StudentProfile, User
from .serializers import UserSerializer

PASSWORD = 'Str0ngPass123'
DEVICE_A = 'device-aaaa-1111'
DEVICE_B = 'device-bbbb-2222'


class DeviceBindingTestBase(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.student = User.objects.create_user(
            username='bind_student',
            password=PASSWORD,
            email='bind@isu.edu.ph',
            role='student',
            is_active=True,
        )
        StudentProfile.objects.create(
            user=self.student,
            student_id='22-77777',
            component='CWTS',
            section_code='CWTS-1A',
            course_and_section='BSIT 1A',
            is_email_verified=True,
            is_approved_by_admin=True,
        )
        self.admin = User.objects.create_user(
            username='bind_admin',
            password=PASSWORD,
            role='admin',
            is_active=True,
            is_staff=True,
        )

    def _login(self, device_id=DEVICE_A, secret=None, username=None):
        payload = {
            'username': username or self.student.username,
            'password': PASSWORD,
            'device_id': device_id,
            'device_label': 'Test phone',
            'platform': 'android',
            'app_version': '1.0.0+10',
        }
        if secret:
            payload['device_secret'] = secret
        return self.client.post('/api/login/', payload, format='json')

    def _bind(self):
        response = self._login()
        self.assertEqual(response.status_code, 200, response.data)
        return response.data['device_binding']['device_secret']


class LoginBindingTests(DeviceBindingTestBase):
    def test_first_login_binds_device_and_returns_secret(self):
        response = self._login()

        self.assertEqual(response.status_code, 200, response.data)
        binding = StudentDeviceBinding.objects.get(user=self.student)
        self.assertEqual(binding.device_id, DEVICE_A)
        self.assertEqual(binding.device_label, 'Test phone')
        secret = response.data['device_binding']['device_secret']
        self.assertTrue(secret)
        self.assertTrue(binding.secret_hash.startswith('pbkdf2_'))

    def test_device_without_optional_metadata_binds(self):
        response = self.client.post(
            '/api/login/',
            {
                'username': self.student.username,
                'password': PASSWORD,
                'device_id': DEVICE_A,
            },
            format='json',
        )

        self.assertEqual(response.status_code, 200, response.data)
        binding = StudentDeviceBinding.objects.get(user=self.student)
        self.assertEqual(binding.device_id, DEVICE_A)
        self.assertEqual(binding.device_label, '')
        self.assertTrue(response.data['device_binding']['device_secret'])

    def test_same_device_can_log_in_again(self):
        secret = self._bind()

        response = self._login(secret=secret)

        self.assertEqual(response.status_code, 200, response.data)
        self.assertNotIn('device_secret', response.data['device_binding'])
        self.assertEqual(StudentDeviceBinding.objects.count(), 1)

    def test_same_device_without_secret_is_rejected(self):
        self._bind()

        response = self._login()

        self.assertEqual(response.status_code, 403, response.data)
        self.assertEqual(response.data['code'], 'device_auth_failed')

    def test_second_device_is_rejected(self):
        secret = self._bind()

        response = self._login(device_id=DEVICE_B, secret=secret)

        self.assertEqual(response.status_code, 403, response.data)
        self.assertEqual(response.data['code'], 'device_mismatch')
        binding = StudentDeviceBinding.objects.get(user=self.student)
        self.assertEqual(binding.device_id, DEVICE_A)

    def test_staff_login_is_not_bound(self):
        instructor = User.objects.create_user(
            username='bind_inst',
            password=PASSWORD,
            role='instructor',
            is_active=True,
        )

        response = self._login(username=instructor.username)

        self.assertEqual(response.status_code, 200, response.data)
        self.assertNotIn('device_binding', response.data)
        self.assertFalse(
            StudentDeviceBinding.objects.filter(user=instructor).exists()
        )

    def test_staff_login_with_device_fields_is_not_bound(self):
        instructor = User.objects.create_user(
            username='bind_inst_2',
            password=PASSWORD,
            role='instructor',
            is_active=True,
        )

        response = self._login(username=instructor.username)

        self.assertEqual(response.status_code, 200, response.data)
        self.assertFalse(
            StudentDeviceBinding.objects.filter(user=instructor).exists()
        )


class AdminResetTests(DeviceBindingTestBase):
    def test_admin_reset_allows_a_new_device_to_bind(self):
        old_secret = self._bind()

        reset = self.client.post(
            f'/api/users/{self.student.id}/reset-device/',
            {'admin_user_id': self.admin.id},
            format='json',
        )
        self.assertEqual(reset.status_code, 200, reset.data)
        self.assertFalse(
            StudentDeviceBinding.objects.filter(user=self.student).exists()
        )

        new_login = self._login(device_id=DEVICE_B)
        self.assertEqual(new_login.status_code, 200, new_login.data)
        self.assertTrue(
            new_login.data['device_binding']['device_secret']
        )
        self.assertNotEqual(
            new_login.data['device_binding']['device_secret'], old_secret
        )
        binding = StudentDeviceBinding.objects.get(user=self.student)
        self.assertEqual(binding.device_id, DEVICE_B)

    def test_non_admin_cannot_reset_a_device(self):
        self._bind()

        response = self.client.post(
            f'/api/users/{self.student.id}/reset-device/',
            {'admin_user_id': self.student.id},
            format='json',
        )

        self.assertEqual(response.status_code, 403, response.data)
        self.assertTrue(
            StudentDeviceBinding.objects.filter(user=self.student).exists()
        )

    def test_admin_cannot_reset_a_staff_device(self):
        instructor = User.objects.create_user(
            username='bind_inst_3',
            password=PASSWORD,
            role='instructor',
            is_active=True,
        )

        response = self.client.post(
            f'/api/users/{instructor.id}/reset-device/',
            {'admin_user_id': self.admin.id},
            format='json',
        )

        self.assertEqual(response.status_code, 400, response.data)


class SessionValidationTests(DeviceBindingTestBase):
    def test_valid_device_and_secret_pass(self):
        secret = self._bind()

        response = self.client.post(
            '/api/device/validate/',
            {
                'user_id': self.student.id,
                'device_id': DEVICE_A,
                'device_secret': secret,
            },
            format='json',
        )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertTrue(response.data['valid'])

    def test_other_device_fails(self):
        secret = self._bind()

        response = self.client.post(
            '/api/device/validate/',
            {
                'user_id': self.student.id,
                'device_id': DEVICE_B,
                'device_secret': secret,
            },
            format='json',
        )

        self.assertEqual(response.status_code, 403, response.data)
        self.assertEqual(response.data['code'], 'device_mismatch')

    def test_device_without_binding_fails(self):
        response = self.client.post(
            '/api/device/validate/',
            {
                'user_id': self.student.id,
                'device_id': DEVICE_A,
            },
            format='json',
        )

        self.assertEqual(response.status_code, 403, response.data)
        self.assertEqual(response.data['code'], 'device_not_bound')

    def test_staff_validate_is_allowed_without_binding(self):
        response = self.client.post(
            '/api/device/validate/',
            {'user_id': self.admin.id},
            format='json',
        )

        self.assertEqual(response.status_code, 200, response.data)
        self.assertTrue(response.data['valid'])


class AttendanceGuardTests(DeviceBindingTestBase):
    def _history(self, device_id=None, secret=None):
        headers = {}
        if device_id:
            headers['HTTP_X_DEVICE_ID'] = device_id
        if secret:
            headers['HTTP_X_DEVICE_SECRET'] = secret
        return self.client.get(
            f'/api/attendance/my-history/?student_id={self.student.id}',
            **headers,
        )

    @override_settings(DEVICE_BINDING_ENFORCED=True)
    def test_bound_device_can_read_attendance_history(self):
        secret = self._bind()

        response = self._history(DEVICE_A, secret)

        self.assertEqual(response.status_code, 200, response.data)

    @override_settings(DEVICE_BINDING_ENFORCED=True)
    def test_unbound_request_is_rejected(self):
        self._bind()

        response = self._history()

        self.assertEqual(response.status_code, 403, response.data)
        self.assertIn(
            response.data['code'],
            {'device_mismatch', 'device_auth_failed'},
        )

    @override_settings(DEVICE_BINDING_ENFORCED=True)
    def test_other_device_is_rejected(self):
        secret = self._bind()

        response = self._history(DEVICE_B, secret)

        self.assertEqual(response.status_code, 403, response.data)
        self.assertEqual(response.data['code'], 'device_mismatch')

    @override_settings(DEVICE_BINDING_ENFORCED=False)
    def test_legacy_client_still_works_during_rollout(self):
        self._bind()

        response = self._history()

        self.assertEqual(response.status_code, 200, response.data)


class SerializerTests(DeviceBindingTestBase):
    def test_bound_device_summary_is_exposed_without_secret(self):
        self._bind()

        data = UserSerializer(self.student).data

        self.assertEqual(data['bound_device']['label'], 'Test phone')
        self.assertEqual(data['bound_device']['platform'], 'android')
        self.assertNotIn('device_secret', data['bound_device'])
        self.assertNotIn('secret_hash', data['bound_device'])
