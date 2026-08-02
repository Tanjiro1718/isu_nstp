"""Checks the 20-40 minute spacing of the random presence pings."""

from django.test import TestCase
from django.utils import timezone

from .models import (
    AttendanceRecord,
    AttendanceSession,
    PRESENCE_GAP_MAX_MINUTES,
    PRESENCE_GAP_MIN_MINUTES,
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

    def _session(self, duration_minutes, check_count):
        return AttendanceSession.objects.create(
            instructor=self.instructor,
            title='Tree Planting',
            date_time=timezone.now(),
            target_latitude=16.9240,
            target_longitude=121.7516,
            radius_meters=50,
            duration_minutes=duration_minutes,
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

    def test_gaps_are_between_20_and_40_minutes(self):
        session = self._session(duration_minutes=480, check_count=6)
        record = self._record(session)

        checks = record.schedule_presence_checks()
        self.assertEqual(len(checks), 6)

        previous = record.timestamp
        for check in sorted(checks, key=lambda c: c.scheduled_at):
            gap = (check.scheduled_at - previous).total_seconds() / 60
            self.assertGreaterEqual(round(gap), PRESENCE_GAP_MIN_MINUTES)
            self.assertLessEqual(round(gap), PRESENCE_GAP_MAX_MINUTES)
            previous = check.scheduled_at

    def test_sequences_are_numbered_in_order(self):
        session = self._session(duration_minutes=480, check_count=4)
        record = self._record(session)

        checks = record.schedule_presence_checks()
        self.assertEqual([c.sequence for c in checks], [1, 2, 3, 4])

    def test_short_session_gets_fewer_pings_not_late_ones(self):
        # A 30 minute activity cannot fit 4 pings that are 20+ minutes apart.
        session = self._session(duration_minutes=30, check_count=4)
        record = self._record(session)

        checks = record.schedule_presence_checks()
        self.assertLess(len(checks), 4)
        for check in checks:
            self.assertLessEqual(check.scheduled_at, session.ends_at)

    def test_zero_count_schedules_nothing(self):
        session = self._session(duration_minutes=120, check_count=0)
        record = self._record(session)

        self.assertEqual(record.schedule_presence_checks(), [])
        self.assertEqual(record.presence_checks.count(), 0)
