"""
Cancelling an attendance session.

Cancelling is a soft action: the session row and any attendance already
recorded stay for the audit trail, but nothing cancelled may reach students or
appear in reports. These tests pin both halves of that promise.
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
from .session_alerts import dispatch_due_session_alerts


class SessionCancelTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.instructor = User.objects.create_user(
            username='cancel_inst',
            password='Str0ngPass123',
            first_name='Juan',
            last_name='Dela Cruz',
            role='instructor',
        )
        self.other_instructor = User.objects.create_user(
            username='cancel_other',
            password='Str0ngPass123',
            role='instructor',
        )

        self.class_group = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 1A',
            component='CWTS',
            section_code='CWTS-1A',
        )

        joined = timezone.now() - timedelta(days=30)
        student_user = User.objects.create_user(
            username='22-00500',
            password='Str0ngPass123',
            first_name='Ana',
            last_name='Reyes',
            role='student',
        )
        self.student = StudentProfile.objects.create(
            user=student_user,
            student_id='22-00500',
            component='CWTS',
            section_code='CWTS-1A',
            course_and_section='BSIT 1A',
        )
        enrollment = ClassEnrollment.objects.create(
            class_group=self.class_group, student=self.student, status='active'
        )
        ClassEnrollment.objects.filter(pk=enrollment.pk).update(joined_at=joined)

        now = timezone.now()
        self.completed = self._session('Finished', now - timedelta(days=2))
        self.ongoing = self._session('Running Now', now - timedelta(minutes=10))
        self.upcoming = self._session('Tomorrow', now + timedelta(days=1))

        # Ana is on site for the running activity.
        self.record = AttendanceRecord.objects.create(
            session=self.ongoing,
            student=self.student,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
            presence_status='ok',
            check_out_at=timezone.now(),
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

    def _cancel(self, session, instructor=None):
        return self.client.post(
            f'/api/instructor/sessions/{session.id}/cancel/',
            {
                'instructor_id': (instructor or self.instructor).id,
            },
            format='json',
        )

    def _instructor_sessions(self):
        return self.client.get(
            f'/api/instructor/sessions/?instructor_id={self.instructor.id}'
        )

    def _student_id(self):
        return self.student.user_id

    # ---------------------------------------------------------------
    # The cancel endpoint
    # ---------------------------------------------------------------

    def test_cancelling_an_upcoming_session_stamps_it(self):
        response = self._cancel(self.upcoming)
        self.assertEqual(response.status_code, 200)

        self.upcoming.refresh_from_db()
        self.assertIsNotNone(self.upcoming.cancelled_at)
        self.assertEqual(self.upcoming.cancelled_by_id, self.instructor.id)

    def test_cancelling_a_running_session_is_allowed(self):
        response = self._cancel(self.ongoing)
        self.assertEqual(response.status_code, 200)
        self.ongoing.refresh_from_db()
        self.assertIsNotNone(self.ongoing.cancelled_at)

    def test_a_completed_session_cannot_be_cancelled(self):
        response = self._cancel(self.completed)
        self.assertEqual(response.status_code, 400)
        self.completed.refresh_from_db()
        self.assertIsNone(self.completed.cancelled_at)

    def test_only_the_owner_can_cancel(self):
        response = self._cancel(self.upcoming, instructor=self.other_instructor)
        self.assertEqual(response.status_code, 403)
        self.upcoming.refresh_from_db()
        self.assertIsNone(self.upcoming.cancelled_at)

    def test_cancelling_twice_is_rejected(self):
        self.assertEqual(self._cancel(self.upcoming).status_code, 200)
        self.assertEqual(self._cancel(self.upcoming).status_code, 400)

    def test_missing_instructor_id_is_rejected(self):
        response = self.client.post(
            f'/api/instructor/sessions/{self.upcoming.id}/cancel/', {}, format='json'
        )
        self.assertEqual(response.status_code, 400)

    def test_unknown_session_is_a_404(self):
        response = self.client.post(
            '/api/instructor/sessions/999999/cancel/',
            {'instructor_id': self.instructor.id},
            format='json',
        )
        self.assertEqual(response.status_code, 404)

    # ---------------------------------------------------------------
    # What cancellation hides
    # ---------------------------------------------------------------

    def test_instructor_list_marks_it_cancelled(self):
        self._cancel(self.ongoing)
        response = self._instructor_sessions()
        self.assertEqual(response.status_code, 200)

        rows = {s['session_id']: s for s in response.data['sessions']}
        self.assertEqual(rows[self.ongoing.id]['status'], 'Cancelled')
        self.assertTrue(rows[self.ongoing.id]['is_cancelled'])
        self.assertIsNotNone(rows[self.ongoing.id]['cancelled_at'])

    def test_cancelled_session_is_not_the_students_current_session(self):
        self._cancel(self.ongoing)
        response = self.client.get(
            f'/api/attendance/session/current/?student_id={self._student_id()}'
        )
        if response.status_code == 200:
            self.assertNotEqual(response.data.get('id'), self.ongoing.id)

    def test_cancelled_session_is_not_in_student_history(self):
        self._cancel(self.ongoing)
        response = self.client.get(
            f'/api/attendance/my-history/?student_id={self._student_id()}'
        )
        self.assertEqual(response.status_code, 200)
        session_ids = {r['session_id'] for r in response.data['records']}
        self.assertNotIn(self.ongoing.id, session_ids)

    def test_cancelled_session_is_not_offered_for_a_future_excuse(self):
        self._cancel(self.upcoming)
        response = self.client.get(
            f'/api/attendance/upcoming-sessions/?student_id={self._student_id()}'
        )
        self.assertEqual(response.status_code, 200)
        session_ids = {r['session_id'] for r in response.data['sessions']}
        self.assertNotIn(self.upcoming.id, session_ids)

    def test_records_are_kept_but_excluded_from_director_records(self):
        self._cancel(self.ongoing)
        # The audit trail survives.
        self.assertTrue(
            AttendanceRecord.objects.filter(session=self.ongoing).exists()
        )

        day = timezone.localtime(self.ongoing.date_time).strftime('%Y-%m-%d')
        response = self.client.get(
            f'/api/director/records/?class_id={self.class_group.id}&date={day}'
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['records'], [])

    def test_records_are_excluded_from_director_export(self):
        self._cancel(self.ongoing)
        response = self.client.get(
            f'/api/director/export/?mode=class&class_id={self.class_group.id}'
        )
        self.assertEqual(response.status_code, 200)
        # The cancelled activity contributes no rows; other activities still do.
        session_ids = {r['session_id'] for r in response.data['records']}
        self.assertNotIn(self.ongoing.id, session_ids)

    def test_check_in_is_rejected_for_a_cancelled_session(self):
        # A fresh running session with no record for Ana, so the only thing
        # that can stop the check-in is the cancellation itself.
        fresh = self._session('Cancelled Run', timezone.now() - timedelta(minutes=5))
        self._cancel(fresh)

        response = self.client.post(
            '/api/attendance/check-in/',
            {
                'session_id': fresh.id,
                'student_id': self._student_id(),
                'latitude': 17.0,
                'longitude': 121.0,
            },
            format='json',
        )
        self.assertEqual(response.status_code, 400)
        self.assertFalse(
            AttendanceRecord.objects.filter(session=fresh).exists()
        )

    def test_cancelled_upcoming_session_sends_no_reminder(self):
        # Bring the reminder due, then cancel it.
        AttendanceSession.objects.filter(pk=self.upcoming.pk).update(
            date_time=timezone.now() + timedelta(minutes=3),
            reminder_sent_at=None,
            start_notified_at=None,
        )
        self._cancel(self.upcoming)
        # Call off the running one too, so the only notification in play would
        # be the cancelled upcoming session's reminder.
        self._cancel(self.ongoing)

        result = dispatch_due_session_alerts(force=True)
        self.assertEqual(result['reminders'], 0)
        self.assertEqual(result['starts'], 0)

        self.upcoming.refresh_from_db()
        self.assertIsNone(self.upcoming.reminder_sent_at)
