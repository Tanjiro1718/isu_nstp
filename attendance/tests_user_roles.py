"""
Covers the admin "Add New User" flow assigning a real role.

The bug this pins down: `role` used to be a SerializerMethodField, which is
read-only, so the role the admin picked was dropped and every account fell back
to the model default ('student'). A new instructor then logged in and landed on
the student dashboard.
"""

from django.test import TestCase
from rest_framework.test import APIClient

from .models import StudentProfile, User
from .serializers import UserSerializer


class UserRoleSerializerTests(TestCase):
    def test_role_is_writable(self):
        serializer = UserSerializer(data={
            'username': 'new_inst',
            'email': 'inst@isu.edu.ph',
            'password': 'Str0ngPass!23',
            'role': 'instructor',
        })
        self.assertTrue(serializer.is_valid(), serializer.errors)
        # The regression was the role never reaching validated_data at all.
        self.assertEqual(serializer.validated_data.get('role'), 'instructor')

    def test_instructor_is_saved_with_instructor_role(self):
        serializer = UserSerializer(data={
            'username': 'inst_two',
            'email': 'inst2@isu.edu.ph',
            'password': 'Str0ngPass!23',
            'role': 'instructor',
        })
        self.assertTrue(serializer.is_valid(), serializer.errors)
        user = serializer.save()

        user.refresh_from_db()
        self.assertEqual(user.role, 'instructor')
        # Staff accounts must not get a student profile attached.
        self.assertFalse(
            StudentProfile.objects.filter(user=user).exists()
        )

    def test_director_is_saved_with_director_role(self):
        serializer = UserSerializer(data={
            'username': 'dir_one',
            'email': 'dir@isu.edu.ph',
            'password': 'Str0ngPass!23',
            'role': 'director',
        })
        self.assertTrue(serializer.is_valid(), serializer.errors)
        user = serializer.save()

        user.refresh_from_db()
        self.assertEqual(user.role, 'director')

    def test_admin_role_also_gets_staff_flags(self):
        serializer = UserSerializer(data={
            'username': 'adm_one',
            'email': 'adm@isu.edu.ph',
            'password': 'Str0ngPass!23',
            'role': 'admin',
        })
        self.assertTrue(serializer.is_valid(), serializer.errors)
        user = serializer.save()

        self.assertEqual(user.role, 'admin')
        self.assertTrue(user.is_staff)
        self.assertTrue(user.is_superuser)

    def test_bad_role_is_rejected(self):
        serializer = UserSerializer(data={
            'username': 'bogus',
            'password': 'Str0ngPass!23',
            'role': 'principal',
        })
        self.assertFalse(serializer.is_valid())
        self.assertIn('role', serializer.errors)

    def test_superuser_without_role_still_reads_as_admin(self):
        """Legacy accounts predate the role field; don't strand them."""
        user = User.objects.create_superuser(
            username='legacy_admin', password='x', email='l@x.com'
        )
        User.objects.filter(pk=user.pk).update(role='')
        user.refresh_from_db()

        self.assertEqual(UserSerializer(user).data['role'], 'admin')


class LoginRoleRoutingTests(TestCase):
    """The app switches dashboards on the role in the login response."""

    def setUp(self):
        self.client = APIClient()

    def _create_via_api_shape(self, username, role):
        serializer = UserSerializer(data={
            'username': username,
            'email': f'{username}@isu.edu.ph',
            'password': 'Str0ngPass!23',
            'role': role,
        })
        self.assertTrue(serializer.is_valid(), serializer.errors)
        return serializer.save()

    def _login(self, username):
        response = self.client.post(
            '/api/login/',
            {'username': username, 'password': 'Str0ngPass!23'},
            format='json',
        )
        self.assertEqual(response.status_code, 200, response.data)
        return response.data['user']['role']

    def test_instructor_login_returns_instructor_role(self):
        self._create_via_api_shape('route_inst', 'instructor')
        self.assertEqual(self._login('route_inst'), 'instructor')

    def test_director_login_returns_director_role(self):
        self._create_via_api_shape('route_dir', 'director')
        self.assertEqual(self._login('route_dir'), 'director')
