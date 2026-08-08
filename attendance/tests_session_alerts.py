"""
Scheduled sessions: the reminder, the start push, and the early check-in gate.

The risk here is notification spam and misinformation. A class must be told
exactly once that an activity is about to begin, exactly once that it has
begun, and must never be nagged about something that already finished. The
sweep runs off ordinary web traffic rather than a scheduler, so these tests
drive it directly at chosen moments instead of waiting on the clock.
"""

from datetime import timedelta
from unittest.mock import patch

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from .models import (
    AttendanceSession,
    ClassEnrollment,
    ClassGroup,
    StudentProfile,
    User,
)
from .session_alerts import dispatch_due_session_alerts


class SessionAlertTestBase(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.instructor = User.objects.create_user(
            username='inst_alerts', password='Str0ngPass123', role='instructor'
        )
        self.class_group = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 1 - Alerts',
            component='CWTS',
            section_code='CWTS-1C',
        )
        self.student = self._enroll('22-20001', 'Migs', 'Santos')

    def _enroll(self, student_id, first, last, status='active'):
        user = User.objects.create_user(
            username=student_id,
            password='Str0ngPass123',
            first_name=first,
            last_name=last,
            role='student',
        )
        profile = StudentProfile.objects.create(
            user=user,
            student_id=student_id,
            component='CWTS',
            section_code='CWTS-1C',
            course_and_section='BSIT 1C',
        )
        ClassEnrollment.objects.create(
            class_group=self.class_group, student=profile, status=status
        )
        return profile

    def _session(self, starts_in_minutes, reminder_minutes=5, class_group=True):
        """An activity scheduled relative to now; negative means it began already."""
        return AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group if class_group else None,
            title='Tree Planting',
            date_time=timezone.now() + timedelta(minutes=starts_in_minutes),
            reminder_minutes=reminder_minutes,
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )


class ReminderDispatchTests(SessionAlertTestBase):
    """The 'starts in N minutes' heads-up."""

    def test_silent_before_the_lead_time(self):
        # Starts in 30 minutes with a 5 minute lead: 25 minutes too early.
        session = self._session(starts_in_minutes=30, reminder_minutes=5)

        with patch('attendance.session_alerts.notify_session_reminder') as push:
            result = dispatch_due_session_alerts(force=True)

        push.assert_not_called()
        self.assertEqual(result['reminders'], 0)
        session.refresh_from_db()
        self.assertIsNone(session.reminder_sent_at)

    def test_fires_once_inside_the_lead_time(self):
        # Starts in 3 minutes, reminder set for 5: the moment has arrived.
        session = self._session(starts_in_minutes=3, reminder_minutes=5)

        with patch('attendance.session_alerts.notify_session_reminder') as push:
            result = dispatch_due_session_alerts(force=True)

        push.assert_called_once()
        self.assertEqual(push.call_args[0][0].pk, session.pk)
        self.assertEqual(result['reminders'], 1)

        session.refresh_from_db()
        self.assertIsNotNone(session.reminder_sent_at)

    def test_never_reminds_the_same_class_twice(self):
        self._session(starts_in_minutes=3, reminder_minutes=5)

        with patch('attendance.session_alerts.notify_session_reminder') as push:
            dispatch_due_session_alerts(force=True)
            # A second sweep moments later must find nothing left to do.
            dispatch_due_session_alerts(force=True)

        self.assertEqual(push.call_count, 1)

    def test_no_reminder_once_the_activity_is_open(self):
        """
        The server may have been idle through the whole lead time. Telling a
        class an activity 'starts in 5 minutes' when it is already running is
        worse than saying nothing - the start push carries the real message.
        """
        self._session(starts_in_minutes=-2, reminder_minutes=5)

        with patch('attendance.session_alerts.notify_session_reminder') as push:
            dispatch_due_session_alerts(force=True)

        push.assert_not_called()

    def test_zero_lead_means_no_advance_warning(self):
        """The instructor chose 'no advance reminder'."""
        self._session(starts_in_minutes=10, reminder_minutes=0)

        with patch('attendance.session_alerts.notify_session_reminder') as push:
            dispatch_due_session_alerts(force=True)

        push.assert_not_called()


class StartDispatchTests(SessionAlertTestBase):
    """The 'attendance is now open' push."""

    def test_not_sent_before_the_start_time(self):
        self._session(starts_in_minutes=15)

        with patch('attendance.session_alerts.notify_session_started') as push:
            dispatch_due_session_alerts(force=True)

        push.assert_not_called()

    def test_sent_once_the_start_time_passes(self):
        session = self._session(starts_in_minutes=-1)

        with patch('attendance.session_alerts.notify_session_started') as push:
            result = dispatch_due_session_alerts(force=True)

        push.assert_called_once()
        self.assertEqual(result['starts'], 1)
        session.refresh_from_db()
        self.assertIsNotNone(session.start_notified_at)

    def test_start_push_is_not_repeated(self):
        self._session(starts_in_minutes=-1)

        with patch('attendance.session_alerts.notify_session_started') as push:
            dispatch_due_session_alerts(force=True)
            dispatch_due_session_alerts(force=True)

        self.assertEqual(push.call_count, 1)

    def test_long_finished_activities_are_left_alone(self):
        """
        First request after a quiet weekend. Waking every stale session would
        blast phones with alerts for activities that are long over.
        """
        self._session(starts_in_minutes=-(60 * 26))

        with patch('attendance.session_alerts.notify_session_started') as push:
            with patch('attendance.session_alerts.notify_session_reminder') as rem:
                dispatch_due_session_alerts(force=True)

        push.assert_not_called()
        rem.assert_not_called()

    def test_sessions_without_a_class_are_ignored(self):
        """No class means no roster to notify."""
        self._session(starts_in_minutes=-1, class_group=False)

        with patch('attendance.session_alerts.notify_session_started') as push:
            dispatch_due_session_alerts(force=True)

        push.assert_not_called()


class EarlyCheckInTests(SessionAlertTestBase):
    """Seeing the reminder must not let a student time in ahead of the start."""

    def _check_in(self, session):
        return self.client.post(
            '/api/attendance/check-in/',
            {
                'session_id': session.id,
                'student_id': self.student.user_id,
                'latitude': 17.0,
                'longitude': 121.0,
            },
            format='json',
        )

    def test_check_in_refused_before_start(self):
        session = self._session(starts_in_minutes=20)

        response = self._check_in(session)

        self.assertEqual(response.status_code, 400)
        self.assertTrue(response.data.get('not_started'))
        # The student is told when to come back, not just that they failed.
        self.assertIn('has not started yet', response.data['message'])

    def test_check_in_allowed_once_started(self):
        """Same student, same request - only the clock differs."""
        session = self._session(starts_in_minutes=-1)

        response = self._check_in(session)

        # It gets past the schedule gate; later rules (photo, geofence) own
        # whatever happens next, so the only thing asserted is the gate.
        self.assertFalse(response.data.get('not_started', False))


class DailyResetTests(SessionAlertTestBase):
    """
    Attendance is a per-day affair: the instructor opens a fresh activity each
    morning and the previous one must stop being offered at local midnight.
    Otherwise a student opening the app the next day is handed yesterday's
    finished activity and walked into a check-in that cannot succeed.
    """

    def _current(self):
        return self.client.get(
            f'/api/attendance/session/current/?student_id={self.student.user_id}'
        )

    def test_todays_session_is_offered(self):
        session = self._session(starts_in_minutes=-30)

        response = self._current()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['id'], session.pk)

    def test_yesterdays_finished_session_is_not_offered(self):
        """The whole point of the reset."""
        self._session(starts_in_minutes=-(60 * 30))  # 30 hours ago

        response = self._current()

        self.assertEqual(response.status_code, 404)
        self.assertIn('today', response.data['message'])

    def test_activity_running_across_midnight_survives(self):
        """
        An evening activity that is still inside its window must not be yanked
        away at 12am - the class would be left unable to time out.

        The clock is frozen at 00:30 rather than offset from the real time,
        otherwise this only exercises the midnight boundary when the suite
        happens to run near midnight.
        """
        midnight = timezone.localtime().replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        session = AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group,
            title='Night Watch',
            date_time=timezone.now(),
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )
        # Began 23:30 last night; its 4-hour window runs past 03:00 today.
        AttendanceSession.objects.filter(pk=session.pk).update(
            date_time=midnight - timedelta(minutes=30)
        )

        with patch(
            'django.utils.timezone.now', return_value=midnight + timedelta(minutes=30)
        ):
            response = self._current()

        # Still inside its window, so it remains the current activity.
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['id'], session.pk)

    def test_last_nights_finished_activity_is_dropped_after_midnight(self):
        """
        The other half of the boundary: once the window has closed, crossing
        midnight must retire it even though it is only hours old.
        """
        midnight = timezone.localtime().replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        session = self._session(starts_in_minutes=0)
        # Began 18:00 last night, so its window shut around 22:00.
        AttendanceSession.objects.filter(pk=session.pk).update(
            date_time=midnight - timedelta(hours=6)
        )

        with patch(
            'django.utils.timezone.now', return_value=midnight + timedelta(minutes=30)
        ):
            response = self._current()

        self.assertEqual(response.status_code, 404)

    def test_todays_session_wins_over_yesterdays(self):
        self._session(starts_in_minutes=-(60 * 30))
        today = self._session(starts_in_minutes=-10)

        response = self._current()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['id'], today.pk)

    def test_session_scheduled_later_today_is_still_offered(self):
        """
        A morning-scheduled activity must be visible before it opens so the
        student can see it is coming; the start gate handles the rest.
        """
        session = self._session(starts_in_minutes=120)

        response = self._current()

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['id'], session.pk)


class ReminderSettingTests(SessionAlertTestBase):
    """What the instructor's form is allowed to send."""

    def _create_session(self, **overrides):
        payload = {
            'instructor': self.instructor.id,
            'class_group': self.class_group.id,
            'title': 'Coastal Clean-up',
            'date_time': (timezone.now() + timedelta(hours=2)).isoformat(),
            'target_latitude': 17.0,
            'target_longitude': 121.0,
            'radius_meters': 100,
        }
        payload.update(overrides)
        return self.client.post(
            '/api/attendance/session/current/', payload, format='json'
        )

    def test_instructor_choice_is_saved(self):
        response = self._create_session(reminder_minutes=30)

        self.assertEqual(response.status_code, 201)
        session = AttendanceSession.objects.get(pk=response.data['id'])
        self.assertEqual(session.reminder_minutes, 30)
        self.assertEqual(
            session.reminder_at, session.date_time - timedelta(minutes=30)
        )

    def test_defaults_to_five_minutes(self):
        """Older app builds omit the field entirely."""
        response = self._create_session()

        self.assertEqual(response.status_code, 201)
        session = AttendanceSession.objects.get(pk=response.data['id'])
        self.assertEqual(session.reminder_minutes, 5)

    def test_absurd_lead_time_is_rejected(self):
        """Almost always hours typed into a minutes box."""
        response = self._create_session(reminder_minutes=5000)

        self.assertEqual(response.status_code, 400)
        self.assertIn('reminder_minutes', response.data)

    def test_client_cannot_pre_stamp_the_alerts(self):
        """
        The stamps are what stop a repeat send. If a client could set them it
        could mute an activity's notifications before they ever fired.
        """
        forged = timezone.now() - timedelta(days=1)
        response = self._create_session(
            reminder_minutes=5,
            reminder_sent_at=forged.isoformat(),
            start_notified_at=forged.isoformat(),
        )

        self.assertEqual(response.status_code, 201)
        session = AttendanceSession.objects.get(pk=response.data['id'])
        self.assertIsNone(session.reminder_sent_at)
        self.assertIsNone(session.start_notified_at)
