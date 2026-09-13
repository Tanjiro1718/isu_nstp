"""
Check-in integrity: one attendance row per student per activity.

The application-level "already timed in" check runs before the insert, so two
concurrent requests could both pass it and create duplicates. These tests pin
the database constraint that makes the race impossible, and the idempotent
check-in that returns the friendly message instead of a 500.
"""

from datetime import timedelta

from django.db import IntegrityError, transaction
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


class CheckInIntegrityTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.instructor = User.objects.create_user(
            username='ci_inst', password='Str0ngPass123', role='instructor'
        )
        self.class_group = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 1A',
            component='CWTS',
            section_code='CWTS-1A',
        )

        self.student_user = User.objects.create_user(
            username='22-00600',
            password='Str0ngPass123',
            first_name='Ana',
            last_name='Reyes',
            role='student',
        )
        self.student = StudentProfile.objects.create(
            user=self.student_user,
            student_id='22-00600',
            component='CWTS',
            section_code='CWTS-1A',
            course_and_section='BSIT 1A',
        )
        enrollment = ClassEnrollment.objects.create(
            class_group=self.class_group, student=self.student, status='active'
        )
        ClassEnrollment.objects.filter(pk=enrollment.pk).update(
            joined_at=timezone.now() - timedelta(days=30)
        )

        # Running now, inside the photo window, so only the duplicate guard can
        # stop a second check-in.
        self.session = AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group,
            title='Tree Planting',
            date_time=timezone.now() - timedelta(minutes=1),
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=200,
        )

    def _record(self):
        return AttendanceRecord.objects.create(
            session=self.session,
            student=self.student,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
        )

    def _check_in(self):
        return self.client.post(
            '/api/attendance/check-in/',
            {
                'session_id': self.session.id,
                'student_id': self.student_user.id,
                'latitude': 17.0,
                'longitude': 121.0,
            },
            format='json',
        )

    def test_a_student_cannot_have_two_records_for_one_session(self):
        self._record()
        with self.assertRaises(IntegrityError):
            with transaction.atomic():
                self._record()

    def test_checking_in_twice_is_rejected_and_keeps_one_record(self):
        first = self._check_in()
        self.assertIn(first.status_code, (200, 201))
        self.assertEqual(
            AttendanceRecord.objects.filter(
                session=self.session, student=self.student
            ).count(),
            1,
        )

        second = self._check_in()
        self.assertEqual(second.status_code, 400)
        self.assertEqual(
            AttendanceRecord.objects.filter(
                session=self.session, student=self.student
            ).count(),
            1,
        )
