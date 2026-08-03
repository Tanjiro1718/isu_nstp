"""
Covers the warn-then-fail escalation for ignored presence checks.

The rule being locked down: a student who times in and then ignores a presence
ping for the whole response window (5 minutes by default) gets a warning and
keeps their time-out. Ignore a second one and the record fails verification,
which closes time-out for good.

FCM is patched out - these tests are about the state machine, not delivery.
"""

import datetime
from unittest.mock import patch

from django.test import TestCase
from django.utils import timezone

from .models import (
    AttendanceRecord,
    AttendanceSession,
    PresenceCheck,
    StudentProfile,
    User,
)
from .presence import dispatch_due_presence_checks


class PresenceEscalationTests(TestCase):
    def setUp(self):
        self.instructor = User.objects.create_user(
            username='inst_esc', password='x', role='instructor'
        )
        student_user = User.objects.create_user(
            username='stud_esc', password='x', role='student'
        )
        self.student = StudentProfile.objects.create(
            user=student_user, student_id='21-9001'
        )

        self.session = AttendanceSession.objects.create(
            instructor=self.instructor,
            title='Coastal Clean-up',
            date_time=timezone.now(),
            target_latitude=16.9240,
            target_longitude=121.7516,
            radius_meters=50,
            duration_minutes=480,
            presence_check_count=3,
            presence_response_minutes=5,
        )
        self.record = AttendanceRecord.objects.create(
            session=self.session,
            student=self.student,
            student_latitude=16.9240,
            student_longitude=121.7516,
            status='Present',
        )

    def _open_time_out(self):
        """
        Open the instructor's time-out window.

        `is_check_out_open` is a stored flag, not derived from the timestamp, so
        both have to be set - otherwise can_check_out is False for a reason that
        has nothing to do with presence and the assertions prove nothing.
        """
        self.session.is_check_out_open = True
        self.session.check_out_opened_at = timezone.now()
        self.session.save(
            update_fields=['is_check_out_open', 'check_out_opened_at']
        )
        self.record.refresh_from_db()
        # Sanity check the fixture itself before relying on it.
        self.assertTrue(self.record.can_check_out)

    def _ignore_one_check(self):
        """
        Push one due check, then let its window lapse without a response.

        Rather than sleeping 5 minutes, the check is backdated so the sweep sees
        an expired window - the same condition a real ignored ping produces.
        """
        now = timezone.now()
        check = PresenceCheck.objects.create(
            record=self.record,
            sequence=PresenceCheck.objects.filter(record=self.record).count() + 1,
            scheduled_at=now,
            status='pending',
        )

        # Sweep once to send it, which stamps expires_at = now + 5 minutes.
        dispatch_due_presence_checks(force=True)
        check.refresh_from_db()
        self.assertEqual(check.status, 'sent')
        self.assertIsNotNone(check.expires_at)

        # Rewind the window so it has provably elapsed, then sweep again.
        elapsed = check.sent_at - datetime.timedelta(minutes=6)
        PresenceCheck.objects.filter(pk=check.pk).update(
            sent_at=elapsed,
            expires_at=elapsed + datetime.timedelta(minutes=5),
        )
        dispatch_due_presence_checks(force=True)

        check.refresh_from_db()
        self.record.refresh_from_db()
        return check

    @patch('attendance.presence.send_presence_failed')
    @patch('attendance.presence.send_presence_warning')
    @patch('attendance.presence.send_presence_check')
    def test_first_ignored_check_warns_but_keeps_time_out(
        self, mock_send, mock_warn, mock_fail
    ):
        mock_send.return_value = True

        self._open_time_out()

        check = self._ignore_one_check()

        self.assertEqual(check.status, 'missed')
        self.assertTrue(check.was_warning)
        self.assertEqual(self.record.missed_checks, 1)
        self.assertEqual(self.record.presence_status, 'warned')

        # The whole point of the amber state: they can still time out.
        self.assertTrue(self.record.can_check_out)

        mock_warn.assert_called_once()
        mock_fail.assert_not_called()

    @patch('attendance.presence.send_presence_failed')
    @patch('attendance.presence.send_presence_warning')
    @patch('attendance.presence.send_presence_check')
    def test_second_ignored_check_fails_and_blocks_time_out(
        self, mock_send, mock_warn, mock_fail
    ):
        mock_send.return_value = True

        self._open_time_out()

        self._ignore_one_check()
        self.assertEqual(self.record.presence_status, 'warned')

        self._ignore_one_check()

        self.assertEqual(self.record.missed_checks, 2)
        self.assertEqual(self.record.presence_status, 'failed')

        # Red state: time-out is gone even though the window is open.
        self.assertFalse(self.record.can_check_out)

        mock_fail.assert_called_once()

    @patch('attendance.presence.send_presence_failed')
    @patch('attendance.presence.send_presence_warning')
    @patch('attendance.presence.send_presence_check')
    def test_failed_record_gets_no_further_pings(
        self, mock_send, mock_warn, mock_fail
    ):
        mock_send.return_value = True

        self._ignore_one_check()
        self._ignore_one_check()
        self.assertEqual(self.record.presence_status, 'failed')

        # Anything still queued is retired rather than pushed - nagging someone
        # who already failed serves no purpose.
        queued = PresenceCheck.objects.create(
            record=self.record,
            sequence=99,
            scheduled_at=timezone.now(),
            status='pending',
        )
        mock_send.reset_mock()
        dispatch_due_presence_checks(force=True)

        queued.refresh_from_db()
        self.assertEqual(queued.status, 'missed')
        mock_send.assert_not_called()

    @patch('attendance.presence.send_presence_warning')
    @patch('attendance.presence.send_presence_check')
    def test_answered_check_leaves_record_ok(self, mock_send, mock_warn):
        mock_send.return_value = True

        now = timezone.now()
        check = PresenceCheck.objects.create(
            record=self.record,
            sequence=1,
            scheduled_at=now,
            status='pending',
        )
        dispatch_due_presence_checks(force=True)

        # Student answers inside the window.
        check.refresh_from_db()
        check.status = 'responded'
        check.responded_at = timezone.now()
        check.save(update_fields=['status', 'responded_at'])

        dispatch_due_presence_checks(force=True)

        self.record.refresh_from_db()
        self.assertEqual(self.record.missed_checks, 0)
        self.assertEqual(self.record.presence_status, 'ok')
        mock_warn.assert_not_called()
