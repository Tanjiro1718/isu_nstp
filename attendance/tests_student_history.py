"""
Student attendance history (My Attendance Record).

The screen left-joins the student's class sessions against their records and
synthesises an 'Absent' row where none exists. The two rules that keep that
honest:

* a session that has not started yet is not an absence - a freshly-enrolled
  student must not look like they skipped activities that are still upcoming;
* a session that ran before the student joined the class was never theirs to
  attend, so it is skipped entirely.
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
    StudentProfile,
    User,
)


class StudentAttendanceHistoryTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.instructor = User.objects.create_user(
            username='inst_history', password='Str0ngPass123', role='instructor'
        )
        self.class_group = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 1 - Sat AM',
            component='CWTS',
            section_code='CWTS-1A',
        )

        self.student_user = User.objects.create_user(
            username='hist_student',
            password='Str0ngPass123',
            first_name='Nina',
            last_name='Santos',
            role='student',
        )
        self.profile = StudentProfile.objects.create(
            user=self.student_user,
            student_id='22-77777',
            component='CWTS',
            section_code='CWTS-1A',
            course_and_section='BSIT 1A',
        )
        self.enrollment = ClassEnrollment.objects.create(
            class_group=self.class_group, student=self.profile, status='active'
        )
        # Joined well before the sessions so the join guard is not the thing
        # under test unless a case says so.
        ClassEnrollment.objects.filter(pk=self.enrollment.pk).update(
            joined_at=timezone.now() - timedelta(days=30)
        )

    def _session(self, title, when):
        return AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group,
            title=title,
            date_time=when,
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )

    def _history(self):
        return self.client.get(
            f'/api/attendance/my-history/?student_id={self.student_user.id}'
        )

    def test_upcoming_session_is_not_an_absence(self):
        """The reported bug: a new student showing absences for future work."""
        self._session('Future Clean-up', timezone.now() + timedelta(days=3))

        response = self._history()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['records'], [])
        self.assertEqual(response.data['summary']['absent'], 0)
        self.assertEqual(response.data['summary']['total_sessions'], 0)

    def test_started_session_without_a_record_is_still_absent(self):
        """Excluding the future must not hide genuine no-shows."""
        self._session('Yesterday', timezone.now() - timedelta(days=1))

        response = self._history()
        self.assertEqual(response.data['summary']['absent'], 1)
        self.assertEqual(response.data['records'][0]['status'], 'Absent')

    def test_future_and_past_sessions_count_only_the_past_one(self):
        self._session('Happened', timezone.now() - timedelta(days=1))
        self._session('Upcoming', timezone.now() + timedelta(days=1))

        response = self._history()
        self.assertEqual(response.data['summary']['total_sessions'], 1)
        self.assertEqual(response.data['summary']['absent'], 1)
        self.assertEqual(
            {r['title'] for r in response.data['records']}, {'Happened'}
        )

    def test_session_before_the_student_joined_is_skipped(self):
        old_session = self._session('Before Join', timezone.now() - timedelta(days=2))
        # Push the enrollment's joined_at to after that session.
        ClassEnrollment.objects.filter(pk=self.enrollment.pk).update(
            joined_at=timezone.now() - timedelta(days=1)
        )

        response = self._history()
        self.assertEqual(response.data['summary']['total_sessions'], 0)
        self.assertNotIn(
            old_session.id, [r['session_id'] for r in response.data['records']]
        )

    def test_present_record_is_reported_as_verified(self):
        past = self._session('Happened', timezone.now() - timedelta(days=1))
        AttendanceRecord.objects.create(
            session=past,
            student=self.profile,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
        )

        response = self._history()
        self.assertEqual(response.data['summary']['verified'], 1)
        self.assertEqual(response.data['summary']['absent'], 0)
