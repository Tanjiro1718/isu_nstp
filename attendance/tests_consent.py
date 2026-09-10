"""
Privacy Policy / Terms & Conditions consent.

New registrations must tick the agreement checkbox (register API rejects
without `accept_terms`). Existing accounts - admins, instructors, directors,
and students created before consent existed - confirm via the /api/consent/
endpoint from the one-time in-app sheet. Both paths stamp the consent
timestamps so the app stops prompting.
"""

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase
from rest_framework.test import APIClient

from .models import User

PASSWORD = 'Str0ngPass123'


class RegisterConsentTests(TestCase):
    def setUp(self):
        self.client = APIClient()

    def _register(self, accept_terms='true'):
        return self.client.post(
            '/api/register/',
            {
                'username': 'consent_stu',
                'email': 'consent_stu@isu.edu.ph',
                'password': PASSWORD,
                'first_name': 'Joan',
                'last_name': 'Doe',
                'course_and_section': 'BSIT-NS 1A',
                'accept_terms': accept_terms,
                'id_picture_front': SimpleUploadedFile(
                    'id.jpg', b'fake-jpeg-bytes', content_type='image/jpeg'
                ),
            },
            format='multipart',
        )

    def test_registration_without_acceptance_is_rejected(self):
        response = self._register(accept_terms='false')
        self.assertEqual(response.status_code, 400)
        self.assertIn(
            'accept the Privacy Policy',
            response.data['detail'],
        )
        self.assertFalse(
            User.objects.filter(username='consent_stu').exists()
        )

    def test_registration_with_acceptance_stamps_consent(self):
        response = self._register(accept_terms='true')
        self.assertIn(response.status_code, (200, 201), response.data)

        user = User.objects.get(username='consent_stu')
        self.assertIsNotNone(user.accepted_terms_at)
        self.assertIsNotNone(user.accepted_privacy_at)


class ConsentAPITests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = User.objects.create_user(
            username='legacy_account',
            email='legacy@isu.edu.ph',
            password=PASSWORD,
            role='instructor',
        )

    def _consent(self, **overrides):
        payload = {
            'user_id': self.user.id,
            'current_password': PASSWORD,
        }
        payload.update(overrides)
        return self.client.post('/api/consent/', payload, format='json')

    def test_legacy_account_can_accept(self):
        response = self._consent()
        self.assertEqual(response.status_code, 200, response.data)
        self.assertIn('Thank you', response.data['message'])

        self.user.refresh_from_db()
        self.assertIsNotNone(self.user.accepted_terms_at)
        self.assertIsNotNone(self.user.accepted_privacy_at)

    def test_response_exposes_consent_state(self):
        response = self._consent()
        self.assertEqual(response.status_code, 200, response.data)
        self.assertIsNotNone(response.data['user']['accepted_terms_at'])
        self.assertIsNotNone(response.data['user']['accepted_privacy_at'])

    def test_missing_fields_are_rejected(self):
        response = self.client.post('/api/consent/', {}, format='json')
        self.assertEqual(response.status_code, 400)

    def test_wrong_password_is_rejected(self):
        response = self._consent(current_password='NopeWrong!')
        self.assertEqual(response.status_code, 400)
        self.user.refresh_from_db()
        self.assertIsNone(self.user.accepted_terms_at)

    def test_account_not_found(self):
        response = self._consent(user_id=999999)
        self.assertEqual(response.status_code, 404)

    def test_idempotent(self):
        first = self._consent()
        self.assertEqual(first.status_code, 200, first.data)
        second = self._consent()
        self.assertEqual(second.status_code, 200, second.data)

        self.user.refresh_from_db()
        self.assertIsNotNone(self.user.accepted_terms_at)


class TermsPagesTests(TestCase):
    def test_privacy_policy_page_renders(self):
        response = self.client.get('/privacy-policy/')
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'Privacy Policy')

    def test_terms_conditions_page_renders(self):
        response = self.client.get('/terms-conditions/')
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, 'Terms &amp; Conditions')

    def test_terms_links_to_privacy_policy(self):
        response = self.client.get('/terms-conditions/')
        self.assertContains(response, '/privacy-policy/')

    def test_privacy_policy_links_to_terms(self):
        response = self.client.get('/privacy-policy/')
        self.assertContains(response, '/terms-conditions/')