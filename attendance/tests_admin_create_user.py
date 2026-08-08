"""
End-to-end version of the admin "Add New User" flow.

tests_user_roles.py drives the serializer directly; this drives the actual
HTTP endpoints the Flutter app calls, in the exact shape it calls them
(form-encoded body, is_active as the string 'true'), so a regression in the
viewset or in request parsing is caught too.
"""

from django.test import TestCase
from rest_framework.test import APIClient

from .models import StudentProfile, User

PASSWORD = 'Str0ngPass123'


class AdminCreatesStaffTests(TestCase):
    def setUp(self):
        self.client = APIClient()

    def _add_user(self, username, role):
        """Mirrors _createUser() in admin_manage_users_screen.dart."""
        return self.client.post(
            '/api/users/',
            {
                'username': username,
                'email': f'{username}@isu.edu.ph',
                'password': PASSWORD,
                'role': role,
                'is_active': 'true',
            },
        )

    def _login(self, username):
        return self.client.post(
            '/api/login/',
            {'username': username, 'password': PASSWORD},
            format='json',
        )

    def test_instructor_is_created_and_lands_on_instructor_dashboard(self):
        response = self._add_user('new_instructor', 'instructor')
        self.assertIn(response.status_code, (200, 201), response.data)

        user = User.objects.get(username='new_instructor')
        self.assertEqual(user.role, 'instructor')

        # The app switches dashboards purely on this value.
        login = self._login('new_instructor')
        self.assertEqual(login.status_code, 200, login.data)
        self.assertEqual(login.data['user']['role'], 'instructor')

    def test_director_is_created_and_lands_on_director_dashboard(self):
        response = self._add_user('new_director', 'director')
        self.assertIn(response.status_code, (200, 201), response.data)

        user = User.objects.get(username='new_director')
        self.assertEqual(user.role, 'director')

        login = self._login('new_director')
        self.assertEqual(login.status_code, 200, login.data)
        self.assertEqual(login.data['user']['role'], 'director')

    def test_staff_accounts_get_no_student_profile(self):
        """A stray StudentProfile would make staff show up in class rosters."""
        for username, role in (('inst_np', 'instructor'), ('dir_np', 'director')):
            self._add_user(username, role)
            user = User.objects.get(username=username)
            self.assertFalse(
                StudentProfile.objects.filter(user=user).exists(),
                f'{role} should not have a StudentProfile',
            )

    def test_instructor_does_not_get_superuser_powers(self):
        self._add_user('plain_inst', 'instructor')
        user = User.objects.get(username='plain_inst')
        self.assertFalse(user.is_staff)
        self.assertFalse(user.is_superuser)

    def test_created_staff_appears_in_the_active_user_list(self):
        """The admin list is filtered by is_active=true; 'true' is a string."""
        self._add_user('listed_dir', 'director')

        response = self.client.get('/api/users/?is_active=true')
        self.assertEqual(response.status_code, 200)

        rows = response.data['results'] if isinstance(response.data, dict) else response.data
        match = [r for r in rows if r['username'] == 'listed_dir']
        self.assertEqual(len(match), 1, 'new director missing from the list')
        self.assertEqual(match[0]['role'], 'director')
