from django.core.files.storage import Storage
from django.test import TestCase
from rest_framework.test import APIRequestFactory

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