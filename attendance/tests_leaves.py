"""
Instructor leave queue: today's requests must actually show up.

The queue filters by the session's calendar day. On MySQL a `__date` lookup is
silently NULL, which made the queue always empty - so these tests pin the
explicit local-day range that replaces it.
"""

from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from .models import (
    AttendanceRecord,
    AttendanceSession,
    ClassEnrollment,
    ClassGroup,
    GeofenceLeaveRequest,
    StudentProfile,
    User,
)


class PendingLeavesTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.instructor = User.objects.create_user(
            username='leave_inst', password='Str0ngPass123', role='instructor'
        )
        self.class_group = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 1A',
            component='CWTS',
            section_code='CWTS-1A',
        )

        student_user = User.objects.create_user(
            username='22-00700',
            password='Str0ngPass123',
            first_name='Ana',
            last_name='Reyes',
            role='student',
        )
        self.student = StudentProfile.objects.create(
            user=student_user,
            student_id='22-00700',
            component='CWTS',
            section_code='CWTS-1A',
            course_and_section='BSIT 1A',
        )
        ClassEnrollment.objects.create(
            class_group=self.class_group, student=self.student, status='active'
        )

        self.today_leave = self._leave_for(
            self._session('Today', timezone.now() - timedelta(minutes=1))
        )

    def _session(self, title, date_time):
        return AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group,
            title=title,
            date_time=date_time,
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )

    def _leave_for(self, session):
        record = AttendanceRecord.objects.create(
            session=session,
            student=self.student,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
        )
        return GeofenceLeaveRequest.objects.create(
            record=record,
            session=session,
            student=self.student,
            reason='Restroom break',
            deadline=timezone.now() + timedelta(minutes=15),
        )

    def _queue(self):
        return self.client.get(
            f'/api/attendance/pending-leaves/?instructor_id={self.instructor.id}'
        )

    def test_todays_leave_is_listed(self):
        response = self._queue()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['pending_count'], 1)
        self.assertEqual(len(response.data['leaves']), 1)
        self.assertEqual(response.data['leaves'][0]['id'], self.today_leave.id)

    def test_a_past_leave_is_not_listed(self):
        self._leave_for(self._session('Yesterday', timezone.now() - timedelta(days=1)))

        response = self._queue()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['pending_count'], 1)
        self.assertEqual(len(response.data['leaves']), 1)
        self.assertEqual(response.data['leaves'][0]['id'], self.today_leave.id)
