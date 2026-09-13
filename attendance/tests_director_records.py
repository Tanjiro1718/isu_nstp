"""
Director daily records: one day of campus attendance, one row per student.

The behaviour worth protecting is the roll-up. The director scans names, not
activities, so a student who sat several sessions must appear once - and the
Present / Partial / Absent / Excused label must reflect the whole day, not just
whichever session happened to be processed last.
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


class DirectorRecordsTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.cwts_instructor = User.objects.create_user(
            username='rec_cwts',
            password='Str0ngPass123',
            first_name='Juan',
            last_name='Dela Cruz',
            role='instructor',
        )
        self.lts_instructor = User.objects.create_user(
            username='rec_lts',
            password='Str0ngPass123',
            first_name='Maria',
            last_name='Santos',
            role='instructor',
        )

        joined = timezone.now() - timedelta(days=30)

        self.cwts_class = ClassGroup.objects.create(
            instructor=self.cwts_instructor,
            name='CWTS 1A',
            component='CWTS',
            section_code='CWTS-1A',
        )
        self.lts_class = ClassGroup.objects.create(
            instructor=self.lts_instructor,
            name='LTS 1A',
            component='LTS',
            section_code='LTS-1A',
        )

        # Pinned to the morning so a late-evening test run cannot roll the
        # activity into the next calendar day.
        self.day = timezone.localtime(timezone.now() - timedelta(days=2)).replace(
            hour=9, minute=0, second=0, microsecond=0
        )

        self.cwts_session = self._session(
            self.cwts_class, self.cwts_instructor, 'Tree Planting', self.day
        )

        self.ana = self._enroll(self.cwts_class, '22-00001', 'Ana', 'Reyes', 'CWTS', joined)
        self.ben = self._enroll(self.cwts_class, '22-00002', 'Ben', 'Cruz', 'CWTS', joined)
        self.cara = self._enroll(self.cwts_class, '22-00003', 'Cara', 'Diaz', 'CWTS', joined)
        self.dino = self._enroll(self.cwts_class, '22-00004', 'Dino', 'Enriquez', 'CWTS', joined)
        self.ela = self._enroll(self.cwts_class, '22-00005', 'Ela', 'Flores', 'CWTS', joined)

        self.fritz = self._enroll(self.lts_class, '22-00006', 'Fritz', 'Garcia', 'LTS', joined)
        self.lts_session = self._session(
            self.lts_class, self.lts_instructor, 'Literacy Drive', self.day
        )

        # One clean attendance -> Present.
        self._record(self.cwts_session, self.ana)
        # Turned up but missed a presence check -> Partial.
        self._record(self.cwts_session, self.ben, presence_status='warned')
        # Turned up but never timed out -> Partial.
        self._record(self.cwts_session, self.ela, checked_out=False)
        # Cara is absent, but with an approved excuse -> Excused.
        AttendanceExcuse.objects.create(
            session=self.cwts_session,
            student=self.cara,
            kind='absent',
            reason='Medical appointment',
            status='approved',
        )
        # Dino and Fritz never timed in and filed nothing -> Absent.

    def _enroll(self, class_group, student_id, first, last, component, joined_at):
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
            component=component,
            section_code=class_group.section_code,
            course_and_section='BSIT 1A',
        )
        enrollment = ClassEnrollment.objects.create(
            class_group=class_group, student=profile, status='active'
        )
        ClassEnrollment.objects.filter(pk=enrollment.pk).update(joined_at=joined_at)
        return profile

    def _session(self, class_group, instructor, title, date_time):
        return AttendanceSession.objects.create(
            instructor=instructor,
            class_group=class_group,
            title=title,
            date_time=date_time,
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )

    def _record(self, session, student, presence_status='ok', checked_out=True):
        return AttendanceRecord.objects.create(
            session=session,
            student=student,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
            presence_status=presence_status,
            check_out_at=timezone.now() if checked_out else None,
        )

    def _records(self, **params):
        query = '&'.join(f'{k}={v}' for k, v in params.items())
        return self.client.get(f'/api/director/records/?{query}')

    def _by_id(self, response):
        return {r['student_id']: r for r in response.data['records']}

    def _day(self):
        return timezone.localtime(self.day).strftime('%Y-%m-%d')

    # ---------------------------------------------------------------
    # Roll-up
    # ---------------------------------------------------------------

    def test_each_student_appears_once_with_a_daily_status(self):
        response = self._records(component='CWTS', date=self._day())
        self.assertEqual(response.status_code, 200)

        rows = self._by_id(response)
        self.assertEqual(rows['22-00001']['status'], 'Present')
        self.assertEqual(rows['22-00002']['status'], 'Partial')
        self.assertEqual(rows['22-00005']['status'], 'Partial')
        self.assertEqual(rows['22-00003']['status'], 'Excused')
        self.assertEqual(rows['22-00004']['status'], 'Absent')

    def test_summary_counts_are_unique_students(self):
        response = self._records(component='CWTS', date=self._day())
        summary = response.data['summary']

        self.assertEqual(summary['students'], 5)
        self.assertEqual(summary['present'], 1)
        self.assertEqual(summary['partial'], 2)
        self.assertEqual(summary['excused'], 1)
        self.assertEqual(summary['absent'], 1)
        # The buckets always add up to the roster.
        self.assertEqual(
            summary['present'] + summary['partial']
            + summary['excused'] + summary['absent'],
            summary['students'],
        )

    def test_a_student_with_several_sessions_is_one_row(self):
        cls = ClassGroup.objects.create(
            instructor=self.cwts_instructor,
            name='CWTS 2A',
            component='CWTS',
            section_code='CWTS-2A',
        )
        gina = self._enroll(cls, '22-00010', 'Gina', 'Herrera', 'CWTS',
                            timezone.now() - timedelta(days=30))
        first = self._session(cls, self.cwts_instructor, 'Morning', self.day)
        second = self._session(
            cls, self.cwts_instructor, 'Afternoon', self.day + timedelta(hours=2)
        )
        self._record(first, gina)
        self._record(second, gina)

        response = self._records(class_id=cls.id, date=self._day())
        records = response.data['records']

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]['student_id'], '22-00010')
        self.assertEqual(records[0]['status'], 'Present')
        self.assertEqual(len(records[0]['sessions']), 2)

    def test_missing_one_of_the_days_sessions_makes_the_student_partial(self):
        cls = ClassGroup.objects.create(
            instructor=self.cwts_instructor,
            name='CWTS 3A',
            component='CWTS',
            section_code='CWTS-3A',
        )
        gina = self._enroll(cls, '22-00011', 'Gina', 'Herrera', 'CWTS',
                            timezone.now() - timedelta(days=30))
        first = self._session(cls, self.cwts_instructor, 'Morning', self.day)
        self._session(
            cls, self.cwts_instructor, 'Afternoon', self.day + timedelta(hours=2)
        )
        self._record(first, gina)

        response = self._records(class_id=cls.id, date=self._day())
        self.assertEqual(response.data['records'][0]['status'], 'Partial')

    def test_records_are_sorted_by_name(self):
        response = self._records(component='CWTS', date=self._day())
        names = [r['student_name'] for r in response.data['records']]
        self.assertEqual(names, sorted(names, key=str.lower))

    # ---------------------------------------------------------------
    # Filters
    # ---------------------------------------------------------------

    def test_per_class_filter_narrows_to_that_class(self):
        response = self._records(class_id=self.cwts_class.id, date=self._day())
        self.assertEqual(set(self._by_id(response)), {
            '22-00001', '22-00002', '22-00003', '22-00004', '22-00005',
        })

    def test_per_program_filter_narrows_to_that_program(self):
        response = self._records(component='LTS', date=self._day())
        self.assertEqual(set(self._by_id(response)), {'22-00006'})

    def test_a_quiet_date_returns_nothing(self):
        quiet = timezone.localtime(
            timezone.now() - timedelta(days=40)
        ).strftime('%Y-%m-%d')
        response = self._records(component='CWTS', date=quiet)
        self.assertEqual(response.data['records'], [])
        self.assertEqual(response.data['summary']['students'], 0)

    def test_a_malformed_date_is_rejected(self):
        response = self._records(date='07-08-2026')
        self.assertEqual(response.status_code, 400)

    def test_date_defaults_to_today(self):
        response = self._records()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(
            response.data['date'],
            timezone.localdate().strftime('%Y-%m-%d'),
        )

    # ---------------------------------------------------------------
    # Row rules carried over from the record builder
    # ---------------------------------------------------------------

    def test_students_who_joined_after_the_activity_are_not_listed(self):
        cls = ClassGroup.objects.create(
            instructor=self.cwts_instructor,
            name='CWTS 4A',
            component='CWTS',
            section_code='CWTS-4A',
        )
        self._session(cls, self.cwts_instructor, 'Past', self.day)
        self._enroll(cls, '22-00020', 'Late', 'Joiner', 'CWTS', timezone.now())

        response = self._records(class_id=cls.id, date=self._day())
        self.assertEqual(response.data['records'], [])

    def test_session_list_carries_the_detail_the_app_expands(self):
        response = self._records(component='CWTS', date=self._day())
        ana = self._by_id(response)['22-00001']
        session = ana['sessions'][0]

        self.assertEqual(session['activity'], 'Tree Planting')
        self.assertEqual(session['presence_status'], 'Verified')
        self.assertTrue(session['selfie_verified'] in (True, False))
        self.assertIn('time_in', session)

    def test_upcoming_session_today_is_not_counted_yet(self):
        cls = ClassGroup.objects.create(
            instructor=self.cwts_instructor,
            name='CWTS 5A',
            component='CWTS',
            section_code='CWTS-5A',
        )
        gina = self._enroll(cls, '22-00030', 'Gina', 'Herrera', 'CWTS',
                            timezone.now() - timedelta(days=30))
        future = AttendanceSession.objects.create(
            instructor=self.cwts_instructor,
            class_group=cls,
            title='Later Today',
            date_time=timezone.now() + timedelta(hours=1),
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )
        # The future session must not invent an absence for Gina.
        self.assertIsNotNone(future)
        response = self._records(class_id=cls.id)
        self.assertEqual(response.data['records'], [])
