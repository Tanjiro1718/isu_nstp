"""
Uploaded-file serving (student ID images) in production.

Django only mounts the /media/ route automatically under DEBUG, so - outside
DEBUG - every absolute URL the serializer returns (e.g.
https://host/media/student_ids/x.jpg) used to 404 and the admin could never
view a pending account's ID scan. The project now routes /media/ whenever the
default storage is the filesystem, independent of DEBUG, and the serializer is
expected to expose id_picture_front as an absolute, fetchable URL.
"""

import io

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase
from rest_framework.test import APIClient

PASSWORD = 'Str0ngPass123'


class MediaServingTests(TestCase):
    def setUp(self):
        self.client = APIClient()

    def _register_with_id(self):
        return self.client.post(
            '/api/register/',
            {
                'username': 'media_stu',
                'email': 'media_stu@isu.edu.ph',
                'password': PASSWORD,
                'first_name': 'Ray',
                'last_name': 'De Guzman',
                'id_number': '21-12345',
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

    def test_uploaded_id_is_fetchable_through_media_route(self):
        """The exact scenario that broke: a stored ID scan must be served by
        /media/<path> so the admin's 'View ID' dialog can load it."""
        self.assertEqual(self._register_with_id().status_code, 201)

        pending = self.client.get('/api/users/?is_active=false')
        self.assertEqual(pending.status_code, 200, pending.data)
        record = next(u for u in pending.data if u['username'] == 'media_stu')

        self.assertTrue(record['id_picture_front'])
        self.assertIn('http', record['id_picture_front'])
        self.assertIn('/media/', record['id_picture_front'])

        response = self.client.get(record['id_picture_front'])
        self.assertEqual(response.status_code, 200)
        # The served bytes are exactly what was uploaded.
        self.assertEqual(
            b''.join(response.streaming_content), b'fake-jpeg-bytes'
        )

    def test_media_url_is_absolute(self):
        """build_absolute_uri turns the relative storage path into a full URL,
        which is what Image.network on the phone needs."""
        self.assertEqual(self._register_with_id().status_code, 201)
        pending = self.client.get('/api/users/?is_active=false')
        record = next(u for u in pending.data if u['username'] == 'media_stu')
        self.assertTrue(
            record['id_picture_front'].startswith('http://testserver/media/'),
            record['id_picture_front'],
        )

    def test_media_route_returns_404_for_missing_file(self):
        response = self.client.get('/media/student_ids/does-not-exist.jpg')
        self.assertEqual(response.status_code, 404)
        # An HTML page named after the view / 404, not a redirect to /
        # or a Django no-route surprise.
        self.assertGreater(len(response.content), 0)