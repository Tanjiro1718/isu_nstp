"""
Class Attendance Record: the per-class, per-date view an instructor exports.

The behaviour worth protecting here is that absences appear at all. The rows
are built from the class roster rather than from AttendanceRecords, so a
student who never timed in still shows up as Absent - otherwise the export
would quietly under-report and look better than reality.
"""

import csv
import io
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


class ClassAttendanceRecordsTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.instructor = User.objects.create_user(
            username='inst_rec', password='Str0ngPass123', role='instructor'
        )

        self.class_group = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 1 - Sat AM',
            component='CWTS',
            section_code='CWTS-1A',
        )

        # Enrolled well before the session so nobody is filtered out for
        # having joined late.
        enrolled_at = timezone.now() - timedelta(days=30)

        self.present_student = self._enroll('22-00001', 'Ana', 'Reyes', enrolled_at)
        self.absent_student = self._enroll('22-00002', 'Ben', 'Cruz', enrolled_at)

        self.session = AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group,
            title='Tree Planting',
            date_time=timezone.now() - timedelta(days=1),
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )

        # Only Ana timed in. Ben is the absence the export must not hide.
        self.record = AttendanceRecord.objects.create(
            session=self.session,
            student=self.present_student,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
        )

    def _enroll(self, student_id, first, last, joined_at):
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
            section_code='CWTS-1A',
            course_and_section='BSIT 1A',
        )
        enrollment = ClassEnrollment.objects.create(
            class_group=self.class_group, student=profile, status='active'
        )
        # joined_at is auto_now_add, so push it back explicitly.
        ClassEnrollment.objects.filter(pk=enrollment.pk).update(joined_at=joined_at)
        return profile

    def _records_url(self, **params):
        url = f'/api/classes/{self.class_group.id}/attendance-records/'
        if params:
            query = '&'.join(f'{k}={v}' for k, v in params.items())
            url = f'{url}?{query}'
        return url

    def _local_session_date(self):
        return timezone.localtime(self.session.date_time).strftime('%Y-%m-%d')

    # ---------------------------------------------------------------
    # JSON view
    # ---------------------------------------------------------------

    def test_absent_students_are_included(self):
        """The whole point: a no-show must appear, not vanish from the report."""
        response = self.client.get(self._records_url())
        self.assertEqual(response.status_code, 200)

        rows = {r['student_id']: r for r in response.data['records']}
        self.assertEqual(len(rows), 2)

        self.assertTrue(rows['22-00001']['attended'])
        self.assertEqual(rows['22-00001']['status'], 'Present')

        self.assertFalse(rows['22-00002']['attended'])
        self.assertEqual(rows['22-00002']['status'], 'Absent')
        self.assertEqual(rows['22-00002']['time_in'], '')

    def test_summary_counts_present_and_absent(self):
        response = self.client.get(self._records_url())
        summary = response.data['summary']

        self.assertEqual(summary['expected'], 2)
        self.assertEqual(summary['present'], 1)
        self.assertEqual(summary['absent'], 1)
        self.assertEqual(summary['attendance_rate'], 50.0)

    def test_filtering_by_the_session_date_keeps_the_rows(self):
        response = self.client.get(
            self._records_url(date=self._local_session_date())
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data['records']), 2)

    def test_filtering_by_a_quiet_date_returns_nothing(self):
        response = self.client.get(self._records_url(date='1999-01-01'))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['records'], [])
        self.assertEqual(response.data['summary']['expected'], 0)

    def test_a_malformed_date_is_rejected(self):
        response = self.client.get(self._records_url(date='07-08-2026'))
        self.assertEqual(response.status_code, 400)

    def test_students_who_joined_after_the_activity_are_not_marked_absent(self):
        """Enrolling today must not invent absences for last month's sessions."""
        self._enroll('22-00003', 'Cara', 'Diaz', timezone.now())

        response = self.client.get(self._records_url())
        ids = {r['student_id'] for r in response.data['records']}
        self.assertNotIn('22-00003', ids)

    def test_unknown_class_is_a_404(self):
        response = self.client.get('/api/classes/999999/attendance-records/')
        self.assertEqual(response.status_code, 404)

    # ---------------------------------------------------------------
    # CSV export
    # ---------------------------------------------------------------

    def test_csv_export_is_a_downloadable_attachment(self):
        response = self.client.get(self._records_url(export='csv'))

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response['Content-Type'], 'text/csv')
        self.assertIn('attachment;', response['Content-Disposition'])
        self.assertIn('.csv', response['Content-Disposition'])

    def test_csv_contains_a_header_and_one_row_per_student(self):
        response = self.client.get(self._records_url(export='csv'))
        body = response.content.decode('utf-8')
        rows = list(csv.reader(io.StringIO(body)))

        self.assertEqual(rows[0][0], 'Student ID')
        self.assertEqual(rows[0][1], 'Student Name')

        data_rows = [r for r in rows[1:] if r]
        self.assertEqual(len(data_rows), 2)

        by_id = {r[0]: r for r in data_rows}
        self.assertIn('22-00001', by_id)
        self.assertIn('22-00002', by_id)

    def test_csv_matches_the_json_rows(self):
        """Exported numbers must equal what the screen showed."""
        json_response = self.client.get(self._records_url())
        csv_response = self.client.get(self._records_url(export='csv'))

        json_ids = sorted(r['student_id'] for r in json_response.data['records'])
        csv_rows = list(csv.reader(io.StringIO(csv_response.content.decode())))
        csv_ids = sorted(r[0] for r in csv_rows[1:] if r)

        self.assertEqual(json_ids, csv_ids)

    def test_csv_writes_booleans_as_yes_no(self):
        """'True'/'False' in a spreadsheet cell reads badly; use Yes/No."""
        response = self.client.get(self._records_url(export='csv'))
        rows = list(csv.reader(io.StringIO(response.content.decode())))

        selfie_col = rows[0].index('Selfie Verified')
        values = {r[selfie_col] for r in rows[1:] if r}
        self.assertTrue(values.issubset({'Yes', 'No'}), values)

    def test_absent_row_carries_a_readable_remark(self):
        response = self.client.get(self._records_url(export='csv'))
        rows = list(csv.reader(io.StringIO(response.content.decode())))

        remarks_col = rows[0].index('Remarks')
        absent_row = next(r for r in rows[1:] if r and r[0] == '22-00002')
        self.assertIn('No time-in', absent_row[remarks_col])


class ClassAttendanceDatesTests(TestCase):
    """The calendar needs to know which days to mark as having data."""

    def setUp(self):
        self.client = APIClient()
        self.instructor = User.objects.create_user(
            username='inst_dates', password='Str0ngPass123', role='instructor'
        )
        self.class_group = ClassGroup.objects.create(
            instructor=self.instructor, name='CWTS 2', component='CWTS'
        )

    def test_dates_are_grouped_and_counted(self):
        # Pinned to the morning so the +3h activity below cannot roll over
        # into the next calendar day - otherwise this test fails whenever it
        # happens to run late in the evening.
        base = timezone.localtime(timezone.now() - timedelta(days=5)).replace(
            hour=9, minute=0, second=0, microsecond=0
        )
        # Two activities on the same day, one on another.
        for offset_hours, title in ((0, 'Morning'), (3, 'Afternoon')):
            AttendanceSession.objects.create(
                instructor=self.instructor,
                class_group=self.class_group,
                title=title,
                date_time=base + timedelta(hours=offset_hours),
                target_latitude=17.0,
                target_longitude=121.0,
                radius_meters=100,
            )
        AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group,
            title='Another Day',
            date_time=base + timedelta(days=2),
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )

        response = self.client.get(
            f'/api/classes/{self.class_group.id}/attendance-dates/'
        )
        self.assertEqual(response.status_code, 200)

        dates = {d['date']: d for d in response.data['dates']}
        self.assertEqual(len(dates), 2)

        grouped_day = timezone.localtime(base).strftime('%Y-%m-%d')
        self.assertEqual(dates[grouped_day]['sessions'], 2)

    def test_class_without_sessions_returns_an_empty_list(self):
        response = self.client.get(
            f'/api/classes/{self.class_group.id}/attendance-dates/'
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['dates'], [])
