from unittest.mock import patch

from django.core.files.storage import Storage
from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, TransactionTestCase
from rest_framework.test import APIClient, APIRequestFactory

from .models import StudentProfile, User
from .serializers import UserSerializer


class BrokenURLStorage(Storage):
    """Mimics an S3/Supabase backend with an empty endpoint URL: any
    url() call raises ValueError, like the Render misconfiguration that
    crashed student login / the admin user list."""

    def _open(self, name, mode='rb'):  # pragma: no cover
        raise NotImplementedError

    def _save(self, name, content):  # pragma: no cover
        raise NotImplementedError

    def url(self, name):
        raise ValueError('Invalid endpoint: ')


class BrokenSaveStorage(Storage):
    """Same misconfiguration, but exercised through the write path: saving the
    student's ID photo raises ``ValueError: Invalid endpoint:``."""

    def _open(self, name, mode='rb'):  # pragma: no cover
        raise NotImplementedError

    def exists(self, name):
        return False

    def _save(self, name, content):
        raise ValueError('Invalid endpoint: ')

    def url(self, name):
        raise ValueError('Invalid endpoint: ')


class StorageFailureSerializationTests(TestCase):
    """A broken storage backend must never crash serialization."""

    def setUp(self):
        self.factory = APIRequestFactory()
        self.user = User.objects.create_user(
            username='stu_broken',
            password='pw',
            email='stu_broken@isu.edu.ph',
            role='student',
        )
        self.profile = StudentProfile.objects.create(
            user=self.user,
            student_id='2020-0001',
            course_and_section='CWTS 1 - A',
            component='CWTS 1',
            section_code='A',
        )

    def test_id_picture_url_failure_does_not_crash_student_serialization(self):
        field = StudentProfile._meta.get_field('id_picture_front')
        original_storage = field.storage
        field.storage = BrokenURLStorage()
        try:
            self.profile.id_picture_front = 'student_ids/x.jpg'
            self.profile.save(update_fields=['id_picture_front'])

            request = self.factory.get('/api/users/')
            data = UserSerializer(self.user, context={'request': request}).data

            self.assertIsNone(data['id_picture_front'])
        finally:
            field.storage = original_storage


class RegistrationStorageFailureTests(TransactionTestCase):
    """An unreachable ID-photo store must not roll back the account - the
    student still registers and can be asked to re-upload manually.

    TransactionTestCase (not TestCase): the failed write marks the enclosing
    atomic block as broken, which would poison the test's own transaction."""

    def test_registration_survives_id_photo_storage_failure(self):
        field = StudentProfile._meta.get_field('id_picture_front')
        original_storage = field.storage
        field.storage = BrokenSaveStorage()
        try:
            client = APIClient()
            with patch('attendance.views.EmailMultiAlternatives.send', return_value=1):
                response = client.post(
                    '/api/register/',
                    {
                        'username': 'broken_stu',
                        'email': 'broken_stu@isu.edu.ph',
                        'password': 'Str0ngPass123',
                        'first_name': 'Broken',
                        'last_name': 'Storage',
                        'id_number': '21-88888',
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

            self.assertEqual(response.status_code, 201, response.data)
            self.assertTrue(response.data.get('photo_upload_failed'))

            user = User.objects.get(email='broken_stu@isu.edu.ph')
            profile = StudentProfile.objects.get(user=user)
            self.assertFalse(profile.id_picture_front)
        finally:
            field.storage = original_storage