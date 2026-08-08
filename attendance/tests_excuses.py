"""
Excuse letters: a student explains a miss, the instructor rules on it.

The behaviour worth protecting is the authority boundary. A student can file
and edit a letter, but only the instructor who owns the activity can decide
it, and an approved no-show is the only thing that rewrites an attendance
record. Everything else - a rejection, a missed-check approval - must leave
the underlying attendance data exactly as it was.
"""

from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from .models import (
    AttendanceExcuse,
    AttendanceRecord,
    AttendanceSession,
    ClassEnrollment,
    ClassGroup,
    StudentProfile,
    User,
)


class ExcuseTestBase(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.instructor = User.objects.create_user(
            username='inst_exc', password='Str0ngPass123', role='instructor'
        )
        self.other_instructor = User.objects.create_user(
            username='inst_other', password='Str0ngPass123', role='instructor'
        )

        self.class_group = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 1 - Excuses',
            component='CWTS',
            section_code='CWTS-1B',
        )

        self.student = self._enroll('22-10001', 'Ana', 'Reyes')

        # Already happened: you cannot excuse an activity that has not run.
        self.session = AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group,
            title='Coastal Clean-up',
            date_time=timezone.now() - timedelta(days=1),
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )

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
            section_code='CWTS-1B',
            course_and_section='BSIT 1B',
        )
        enrollment = ClassEnrollment.objects.create(
            class_group=self.class_group, student=profile, status=status
        )
        ClassEnrollment.objects.filter(pk=enrollment.pk).update(
            joined_at=timezone.now() - timedelta(days=30)
        )
        return profile

    def _submit(self, student=None, session=None, reason='I was ill and stayed home.'):
        return self.client.post(
            '/api/excuses/',
            {
                'student_id': (student or self.student).user_id,
                'session_id': (session or self.session).id,
                'reason': reason,
            },
            format='json',
        )

    def _review(self, excuse_id, decision, instructor=None, note=''):
        payload = {
            'instructor_id': (instructor or self.instructor).id,
            'decision': decision,
        }
        if note:
            payload['response_note'] = note
        return self.client.patch(
            f'/api/excuses/{excuse_id}/review/', payload, format='json'
        )


class SubmitExcuseTests(ExcuseTestBase):
    def test_a_student_can_file_an_excuse_for_a_missed_activity(self):
        response = self._submit()

        self.assertEqual(response.status_code, 201)
        excuse = AttendanceExcuse.objects.get(
            session=self.session, student=self.student
        )
        self.assertEqual(excuse.status, 'pending')
        # No AttendanceRecord exists, so this is a no-show, not a missed ping.
        self.assertEqual(excuse.kind, 'absent')

    def test_kind_is_derived_from_the_data_not_the_client(self):
        """A student who timed in is filing about checks, whatever they claim."""
        AttendanceRecord.objects.create(
            session=self.session,
            student=self.student,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
            presence_status='failed',
        )

        response = self.client.post(
            '/api/excuses/',
            {
                'student_id': self.student.user_id,
                'session_id': self.session.id,
                'reason': 'My phone died during the activity.',
                # Deliberately wrong - the server must ignore it.
                'kind': 'absent',
            },
            format='json',
        )

        self.assertEqual(response.status_code, 201)
        excuse = AttendanceExcuse.objects.get(pk=response.data['excuse']['id'])
        self.assertEqual(excuse.kind, 'missed_check')

    def test_a_reason_is_required(self):
        response = self._submit(reason='   ')
        self.assertEqual(response.status_code, 400)
        self.assertFalse(AttendanceExcuse.objects.exists())

    def test_an_activity_that_has_not_started_cannot_be_excused(self):
        future = AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group,
            title='Next Week',
            date_time=timezone.now() + timedelta(days=3),
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )

        response = self._submit(session=future)
        self.assertEqual(response.status_code, 400)
        self.assertFalse(AttendanceExcuse.objects.exists())

    def test_a_non_member_cannot_file_against_someone_elses_class(self):
        outsider_user = User.objects.create_user(
            username='22-99999', password='Str0ngPass123', role='student'
        )
        outsider = StudentProfile.objects.create(
            user=outsider_user, student_id='22-99999', component='CWTS'
        )

        response = self._submit(student=outsider)
        self.assertEqual(response.status_code, 403)
        self.assertFalse(AttendanceExcuse.objects.exists())

    def test_a_complete_attendance_has_nothing_to_excuse(self):
        AttendanceRecord.objects.create(
            session=self.session,
            student=self.student,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
            presence_status='ok',
            check_out_at=timezone.now(),
        )

        response = self._submit()
        self.assertEqual(response.status_code, 400)

    def test_resubmitting_while_pending_edits_the_same_letter(self):
        """Fixing a typo should not queue a second letter for the instructor."""
        self._submit(reason='I was sick.')
        response = self._submit(reason='I was sick and have a medical note.')

        self.assertEqual(response.status_code, 200)
        self.assertEqual(AttendanceExcuse.objects.count(), 1)
        excuse = AttendanceExcuse.objects.get()
        self.assertEqual(excuse.reason, 'I was sick and have a medical note.')

    def test_a_decided_excuse_cannot_be_quietly_refiled(self):
        self._submit()
        excuse = AttendanceExcuse.objects.get()
        self._review(excuse.id, 'reject')

        response = self._submit(reason='Trying again with a better story.')

        self.assertEqual(response.status_code, 409)
        excuse.refresh_from_db()
        self.assertEqual(excuse.status, 'rejected')

    def test_a_student_only_sees_their_own_letters(self):
        classmate = self._enroll('22-10002', 'Ben', 'Cruz')
        self._submit()
        self._submit(student=classmate, reason='Family emergency at home.')

        response = self.client.get(f'/api/excuses/?student_id={self.student.user_id}')

        self.assertEqual(response.status_code, 200)
        # This endpoint answers with a bare list; the instructor queue wraps
        # its rows because it also carries a pending count.
        self.assertEqual(len(response.data), 1)
        self.assertEqual(response.data[0]['student_name'], 'Ana Reyes')


class ReviewExcuseTests(ExcuseTestBase):
    def setUp(self):
        super().setUp()
        self._submit()
        self.excuse = AttendanceExcuse.objects.get()

    def test_the_owning_instructor_can_approve(self):
        response = self._review(self.excuse.id, 'approve', note='Get well soon.')

        self.assertEqual(response.status_code, 200)
        self.excuse.refresh_from_db()
        self.assertEqual(self.excuse.status, 'approved')
        self.assertEqual(self.excuse.response_note, 'Get well soon.')
        self.assertEqual(self.excuse.reviewed_by, self.instructor)
        self.assertIsNotNone(self.excuse.reviewed_at)

    def test_another_instructor_cannot_rule_on_it(self):
        response = self._review(
            self.excuse.id, 'approve', instructor=self.other_instructor
        )

        self.assertEqual(response.status_code, 403)
        self.excuse.refresh_from_db()
        self.assertEqual(self.excuse.status, 'pending')

    def test_a_decision_cannot_be_overwritten(self):
        self._review(self.excuse.id, 'approve')
        response = self._review(self.excuse.id, 'reject')

        self.assertEqual(response.status_code, 409)
        self.excuse.refresh_from_db()
        self.assertEqual(self.excuse.status, 'approved')

    def test_an_unrecognised_decision_is_rejected(self):
        response = self._review(self.excuse.id, 'maybe')

        self.assertEqual(response.status_code, 400)
        self.excuse.refresh_from_db()
        self.assertEqual(self.excuse.status, 'pending')

    def test_approving_a_missed_check_does_not_undo_the_failure(self):
        """Sympathy is recorded, but presence verification still stands."""
        record = AttendanceRecord.objects.create(
            session=self.session,
            student=self.student,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
            presence_status='failed',
        )
        self.excuse.kind = 'missed_check'
        self.excuse.record = record
        self.excuse.save(update_fields=['kind', 'record'])

        self._review(self.excuse.id, 'approve')

        record.refresh_from_db()
        self.assertEqual(record.presence_status, 'failed')

    def test_the_queue_defaults_to_pending_letters_for_this_instructor(self):
        classmate = self._enroll('22-10003', 'Cara', 'Diaz')
        self._submit(student=classmate, reason='Had to travel home for a funeral.')
        self._review(self.excuse.id, 'approve')

        response = self.client.get(
            f'/api/excuses/review-queue/?instructor_id={self.instructor.id}'
        )

        self.assertEqual(response.status_code, 200)
        rows = response.data['excuses']
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['student_name'], 'Cara Diaz')
        self.assertEqual(response.data['pending_count'], 1)

    def test_the_queue_is_scoped_to_the_asking_instructor(self):
        response = self.client.get(
            f'/api/excuses/review-queue/?instructor_id={self.other_instructor.id}'
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['excuses'], [])


class ExcusedInClassRecordTests(ExcuseTestBase):
    """The payoff: an approved no-show stops reading as an absence."""

    def _rows(self):
        response = self.client.get(
            f'/api/classes/{self.class_group.id}/attendance-records/'
        )
        self.assertEqual(response.status_code, 200)
        return response, {r['student_id']: r for r in response.data['records']}

    def test_an_unreviewed_absence_still_counts_against_the_student(self):
        self._submit()

        _, rows = self._rows()
        self.assertEqual(rows['22-10001']['status'], 'Absent')

    def test_an_approved_absence_shows_as_excused(self):
        self._submit()
        excuse = AttendanceExcuse.objects.get()
        self._review(excuse.id, 'approve')

        response, rows = self._rows()
        row = rows['22-10001']
        self.assertEqual(row['status'], 'Excused')
        self.assertFalse(row['attended'])
        self.assertTrue(row['excused'])
        self.assertEqual(response.data['summary']['excused'], 1)
        self.assertEqual(response.data['summary']['absent'], 0)

    def test_a_rejected_absence_remains_an_absence(self):
        self._submit()
        excuse = AttendanceExcuse.objects.get()
        self._review(excuse.id, 'reject', note='No documentation provided.')

        response, rows = self._rows()
        self.assertEqual(rows['22-10001']['status'], 'Absent')
        self.assertEqual(response.data['summary']['excused'], 0)
        self.assertEqual(response.data['summary']['absent'], 1)

    def test_an_excused_absence_does_not_drag_down_the_attendance_rate(self):
        """Excusing one of two no-shows should not read as 0% attendance."""
        self._enroll('22-10004', 'Dan', 'Lim')
        self._submit()
        self._review(AttendanceExcuse.objects.get().id, 'approve')

        response, _ = self._rows()
        summary = response.data['summary']

        # Ana is excused and drops out of the denominator; only Dan is counted.
        self.assertEqual(summary['expected'], 2)
        self.assertEqual(summary['excused'], 1)
        self.assertEqual(summary['absent'], 1)
        self.assertEqual(summary['attendance_rate'], 0.0)

    def test_the_csv_export_reports_the_excused_status(self):
        self._submit()
        self._review(AttendanceExcuse.objects.get().id, 'approve')

        response = self.client.get(
            f'/api/classes/{self.class_group.id}/attendance-records/?export=csv'
        )
        body = response.content.decode('utf-8')

        self.assertEqual(response['Content-Type'], 'text/csv')
        self.assertIn('Excused', body)
