"""
Covers the self-service profile edit endpoint (Profile screen).

Roles governed by the backend: only instructor / director / admin may edit
their own details. Students are rejected server-side even though the Flutter
UI hides the button for them. Username is immutable, and the email must stay
unique across accounts.
"""

from django.test import TestCase
from rest_framework.test import APIClient

from .models import InstructorProfile, StudentProfile, User

PASSWORD = 'Str0ngPass123'


def _make_user(role, username):
    return User.objects.create_user(
        username=username,
        email=f'{username}@isu.edu.ph',
        password=PASSWORD,
        role=role,
    )


class EditProfileAPITests(TestCase):
    def setUp(self):
        self.client = APIClient()

    def _edit(self, user_id, **overrides):
        payload = {
            'user_id': user_id,
            'current_password': PASSWORD,
            'email': 'updated@isu.edu.ph',
            'first_name': 'Juan',
            'middle_name': 'Dela',
            'last_name': 'Cruz',
            'phone_number': '09171234567',
            'department': 'CWTS',
        }
        payload.update(overrides)
        return self.client.post('/api/edit-profile/', payload, format='json')

    def test_instructor_updates_fields_and_department(self):
        user = _make_user('instructor', 'inst_edit')
        response = self._edit(user.id)

        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data['message'], 'Profile updated successfully.')

        user.refresh_from_db()
        self.assertEqual(user.first_name, 'Juan')
        self.assertEqual(user.middle_name, 'Dela')
        self.assertEqual(user.last_name, 'Cruz')
        self.assertEqual(user.phone_number, '09171234567')
        self.assertEqual(user.email, 'updated@isu.edu.ph')

        department = InstructorProfile.objects.get(user=user).department
        self.assertEqual(department, 'CWTS')

    def test_director_updates_details_without_department(self):
        user = _make_user('director', 'dir_edit')
        response = self._edit(user.id, department='')

        self.assertEqual(response.status_code, 200, response.data)
        user.refresh_from_db()
        self.assertEqual(user.email, 'updated@isu.edu.ph')
        # Directors must not gain an InstructorProfile.
        self.assertFalse(
            InstructorProfile.objects.filter(user=user).exists()
        )

    def test_admin_can_edit_profile(self):
        user = _make_user('admin', 'admin_edit')
        response = self._edit(user.id, email='admin-new@isu.edu.ph')
        self.assertEqual(response.status_code, 200, response.data)
        user.refresh_from_db()
        self.assertEqual(user.email, 'admin-new@isu.edu.ph')

    def test_student_is_rejected_server_side(self):
        user = _make_user('student', 'stu_edit')
        response = self._edit(user.id)
        self.assertEqual(response.status_code, 403)
        self.assertIn('Students cannot edit', response.data['detail'])

    def test_username_stays_immutable(self):
        user = _make_user('instructor', 'frozen_name')
        response = self._edit(user.id, username='hacker')
        self.assertEqual(response.status_code, 200, response.data)
        user.refresh_from_db()
        self.assertEqual(user.username, 'frozen_name')

    def test_wrong_password_is_rejected(self):
        user = _make_user('instructor', 'wrongpw')
        response = self._edit(user.id, current_password='NotThePassword!')
        self.assertEqual(response.status_code, 400)
        self.assertIn('Incorrect password', response.data['detail'])

    def test_duplicate_email_is_rejected(self):
        _make_user('instructor', 'existing_email')
        other = _make_user('director', 'taking_email')
        response = self._edit(other.id, email='existing_email@isu.edu.ph')
        self.assertEqual(response.status_code, 400)
        self.assertIn('already in use', response.data['detail'])

    def test_blank_email_keeps_current_value(self):
        user = _make_user('instructor', 'keep_email')
        response = self._edit(user.id, email='')
        self.assertEqual(response.status_code, 200, response.data)
        user.refresh_from_db()
        self.assertEqual(user.email, 'keep_email@isu.edu.ph')

    def test_student_profile_is_unaffected_when_staff_edits(self):
        # A staff edit must never create or touch a StudentProfile, so student
        # dashboards (which read StudentProfile fields) cannot get confused.
        user = _make_user('instructor', 'no_student_profile')
        self._edit(user.id)
        self.assertFalse(StudentProfile.objects.filter(user=user).exists())