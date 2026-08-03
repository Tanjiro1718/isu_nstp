"""Checks the timing of the random presence pings.

Ping 1 lands 20-40 minutes after time-in. Every ping after that waits out a
1 hour cooldown first, so consecutive gaps are 80-100 minutes.
"""

from django.test import TestCase
from django.utils import timezone

from .models import (
    AttendanceRecord,
    AttendanceSession,
    PRESENCE_COOLDOWN_MINUTES,
    PRESENCE_GAP_MAX_MINUTES,
    PRESENCE_GAP_MIN_MINUTES,
    SESSION_DURATION_MINUTES,
    StudentProfile,
    User,
)


class PresenceGapTests(TestCase):
    def setUp(self):
        self.instructor = User.objects.create_user(
            username='inst1', password='x', role='instructor'
        )
        student_user = User.objects.create_user(
            username='stud1', password='x', role='student'
        )
        self.student = StudentProfile.objects.create(
            user=student_user, student_id='21-0001'
        )

    def _session(self, check_count, duration_minutes=None):
        return AttendanceSession.objects.create(
            instructor=self.instructor,
            title='Tree Planting',
            date_time=timezone.now(),
            target_latitude=16.9240,
            target_longitude=121.7516,
            radius_meters=50,
            duration_minutes=(
                SESSION_DURATION_MINUTES
                if duration_minutes is None
                else duration_minutes
            ),
            presence_check_count=check_count,
            presence_response_minutes=5,
        )

    def _record(self, session):
        return AttendanceRecord.objects.create(
            session=session,
            student=self.student,
            student_latitude=16.9240,
            student_longitude=121.7516,
            status='Present',
        )

    def test_session_defaults_to_four_hours(self):
        session = AttendanceSession.objects.create(
            instructor=self.instructor,
            title='Coastal Clean-up',
            date_time=timezone.now(),
            target_latitude=16.9240,
            target_longitude=121.7516,
            radius_meters=50,
        )
        self.assertEqual(session.duration_minutes, 240)
        self.assertEqual(
            (session.ends_at - session.date_time).total_seconds() / 3600, 4
        )

    def test_first_ping_lands_20_to_40_minutes_after_time_in(self):
        session = self._session(check_count=2)
        record = self._record(session)

        checks = record.schedule_presence_checks()
        self.assertEqual(len(checks), 2)

        first = min(checks, key=lambda c: c.scheduled_at)
        gap = (first.scheduled_at - record.timestamp).total_seconds() / 60
        # No cooldown before the very first ping.
        self.assertGreaterEqual(round(gap), PRESENCE_GAP_MIN_MINUTES)
        self.assertLessEqual(round(gap), PRESENCE_GAP_MAX_MINUTES)

    def test_later_pings_wait_out_the_one_hour_cooldown(self):
        session = self._session(check_count=2)
        record = self._record(session)

        checks = sorted(
            record.schedule_presence_checks(), key=lambda c: c.scheduled_at
        )
        self.assertEqual(len(checks), 2)

        gap = (
            checks[1].scheduled_at - checks[0].scheduled_at
        ).total_seconds() / 60
        # Cooldown plus another random 20-40 minutes.
        self.assertGreaterEqual(
            round(gap), PRESENCE_COOLDOWN_MINUTES + PRESENCE_GAP_MIN_MINUTES
        )
        self.assertLessEqual(
            round(gap), PRESENCE_COOLDOWN_MINUTES + PRESENCE_GAP_MAX_MINUTES
        )

    def test_two_pings_always_fit_inside_the_four_hour_window(self):
        # Worst case is 40 + 60 + 40 = 140 minutes, well short of 240, so the
        # default pair must never be dropped for lack of room.
        for _ in range(25):
            session = self._session(check_count=2)
            record = self._record(session)
            checks = record.schedule_presence_checks()

            self.assertEqual(len(checks), 2)
            for check in checks:
                self.assertLessEqual(check.scheduled_at, session.ends_at)
            record.delete()

    def test_sequences_are_numbered_in_order(self):
        session = self._session(check_count=2)
        record = self._record(session)

        checks = record.schedule_presence_checks()
        self.assertEqual([c.sequence for c in checks], [1, 2])

    def test_short_session_gets_fewer_pings_not_late_ones(self):
        # A 30 minute activity cannot fit 4 pings that are 20+ minutes apart.
        session = self._session(check_count=4, duration_minutes=30)
        record = self._record(session)

        checks = record.schedule_presence_checks()
        self.assertLess(len(checks), 4)
        for check in checks:
            self.assertLessEqual(check.scheduled_at, session.ends_at)

    def test_zero_count_schedules_nothing(self):
        session = self._session(check_count=0)
        record = self._record(session)

        self.assertEqual(record.schedule_presence_checks(), [])
        self.assertEqual(record.presence_checks.count(), 0)
