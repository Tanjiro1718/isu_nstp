"""
On-device face verification results at time-in.

The app reports whether the selfie's face matched the student's reference and
how confident it was. That flag must never block time-in: a mismatch or a
missing result still records the check-in, just flagged for instructor review.
"""

from datetime import timedelta
from unittest.mock import patch

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from .models import (
    AttendanceRecord,
    AttendanceSession,
    ClassEnrollment,
    ClassGroup,
    StudentProfile,
    User,
)

from .fcm_utils import send_check_in_notification


class FaceVerificationCheckInTestBase(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.instructor = User.objects.create_user(
            username='inst_face', password='Str0ngPass123', role='instructor'
        )
        self.class_group = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 1 - Face',
            component='CWTS',
            section_code='CWTS-1F',
        )
        self.student_user = User.objects.create_user(
            username='face_student',
            password='Str0ngPass123',
            first_name='Cara',
            last_name='Diaz',
            role='student',
        )
        self.student_profile = StudentProfile.objects.create(
            user=self.student_user,
            student_id='22-44444',
            component='CWTS',
            section_code='CWTS-1F',
            course_and_section='BSIT 1F',
        )
        ClassEnrollment.objects.create(
            class_group=self.class_group,
            student=self.student_profile,
            status='active',
        )

        # Started one minute ago: inside the 5-minute photo window and past the
        # early check-in gate, with the geofence centred on the posted coords.
        self.session = AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group,
            title='Tree Planting',
            date_time=timezone.now() - timedelta(minutes=1),
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )

    def _check_in(self, **extra):
        data = {
            'session_id': self.session.id,
            'student_id': self.student_user.id,
            'latitude': '17.0',
            'longitude': '121.0',
        }
        data.update(extra)
        return self.client.post('/api/attendance/check-in/', data, format='multipart')

    def _selfie(self, name='selfie.jpg', content=b'fake-jpeg-bytes'):
        return SimpleUploadedFile(name, content, content_type='image/jpeg')

    def _record(self):
        return AttendanceRecord.objects.get(
            session=self.session, student=self.student_profile
        )


class FaceVerifiedFlagTests(FaceVerificationCheckInTestBase):
    def test_verified_selfie_marks_record_verified_and_stores_score(self):
        response = self._check_in(
            face_verified='true',
            face_similarity='0.87',
            selfie=self._selfie(),
        )

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.data['face_verified'])
        record = self._record()
        self.assertTrue(record.selfie_verified)
        self.assertAlmostEqual(record.face_similarity, 0.87)

    def test_mismatch_still_records_but_is_flagged(self):
        """A failed match must not block time-in - it just gets flagged."""
        response = self._check_in(
            face_verified='false',
            face_similarity='0.22',
            selfie=self._selfie(),
        )

        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.data['face_verified'])
        record = self._record()
        self.assertFalse(record.selfie_verified)
        self.assertAlmostEqual(record.face_similarity, 0.22)

    def test_no_face_on_file_still_records_as_unverified(self):
        """Missing or unusable reference -> the app omits the verified flag."""
        response = self._check_in(
            face_verified='false',
            face_similarity='0.0',
            selfie=self._selfie(),
        )

        self.assertEqual(response.status_code, 200)
        record = self._record()
        self.assertFalse(record.selfie_verified)
        self.assertEqual(record.face_similarity, 0.0)

    def test_legacy_request_without_flag_uses_selfie_presence(self):
        """Older app builds don't send the field; a selfie counts as verified."""
        response = self._check_in(selfie=self._selfie())

        self.assertEqual(response.status_code, 200)
        record = self._record()
        self.assertTrue(record.selfie_verified)
        self.assertIsNone(record.face_similarity)

    def test_legacy_request_without_selfie_is_unverified(self):
        response = self._check_in()

        self.assertEqual(response.status_code, 200)
        record = self._record()
        self.assertFalse(record.selfie_verified)
        self.assertIsNone(record.face_similarity)

    def test_garbage_similarity_is_ignored(self):
        response = self._check_in(
            face_verified='true',
            face_similarity='not-a-number',
        )

        self.assertEqual(response.status_code, 200)
        self.assertTrue(self._record().selfie_verified)
        self.assertIsNone(self._record().face_similarity)


class InstructorCheckInNotificationTests(FaceVerificationCheckInTestBase):
    def test_check_in_notifies_the_owning_instructor(self):
        """A successful time-in triggers a push to the session's instructor."""
        with patch(
            'attendance.views.send_check_in_notification'
        ) as mock_send:
            response = self._check_in()
            self.assertEqual(response.status_code, 200)
            mock_send.assert_called_once()

            record = self._record()
            mock_send.assert_called_once_with(record)

    def test_check_in_push_skipped_without_instructor_token(self):
        """No device token on the instructor means the push is skipped safely."""
        self.instructor.fcm_token = ''
        self.instructor.save(update_fields=['fcm_token'])

        self.assertIsNone(self.instructor.push_token)
        with patch(
            'attendance.views.send_check_in_notification',
            wraps=send_check_in_notification,
        ):
            response = self._check_in()
            self.assertEqual(response.status_code, 200)

        # The helper returns False (skips) when the instructor has no token.
        self.assertFalse(send_check_in_notification(self._record()))
