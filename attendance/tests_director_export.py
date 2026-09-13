"""
Director campus export: the per-class / per-program / per-instructor / per-day
spreadsheet the NSTP office downloads.

The behaviour worth protecting is that each "Export By" mode actually narrows
the data, that an absence still appears, and that the campus CSV says which
class each row came from - a campus-wide file without that column is unusable.
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


class DirectorExportTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.cwts_instructor = User.objects.create_user(
            username='inst_cwts',
            password='Str0ngPass123',
            first_name='Juan',
            last_name='Dela Cruz',
            role='instructor',
        )
        self.lts_instructor = User.objects.create_user(
            username='inst_lts',
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

        self.cwts_student = self._enroll(
            self.cwts_class, '22-00001', 'Ana', 'Reyes', 'CWTS', joined
        )
        self.lts_student = self._enroll(
            self.lts_class, '22-00002', 'Ben', 'Cruz', 'LTS', joined
        )

        # Two different days so the Per Day filter is meaningful. Pinned to the
        # morning so a late-evening test run cannot roll into the next day.
        base = timezone.localtime(timezone.now() - timedelta(days=2)).replace(
            hour=9, minute=0, second=0, microsecond=0
        )
        self.cwts_session = self._session(
            self.cwts_class, self.cwts_instructor, 'Tree Planting', base
        )
        self.lts_session = self._session(
            self.lts_class, self.lts_instructor, 'Literacy Drive',
            base - timedelta(days=1),
        )

        # Only the CWTS student timed in; the LTS student is the absence.
        AttendanceRecord.objects.create(
            session=self.cwts_session,
            student=self.cwts_student,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
        )

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

    def _export(self, **params):
        query = '&'.join(f'{k}={v}' for k, v in params.items())
        return self.client.get(f'/api/director/export/?{query}')

    def _student_ids(self, response):
        return {r['student_id'] for r in response.data['records']}

    # ---------------------------------------------------------------
    # Mode filtering
    # ---------------------------------------------------------------

    def test_per_class_export_only_includes_that_class(self):
        response = self._export(mode='class', class_id=self.cwts_class.id)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._student_ids(response), {'22-00001'})

        row = response.data['records'][0]
        self.assertEqual(row['class_name'], 'CWTS 1A')
        self.assertEqual(row['component'], 'CWTS')
        self.assertEqual(row['instructor_name'], 'Juan Dela Cruz')

    def test_per_program_export_filters_by_component(self):
        response = self._export(mode='program', component='LTS')
        self.assertEqual(response.status_code, 200)
        # The LTS student never timed in, but is still the one row for LTS.
        self.assertEqual(self._student_ids(response), {'22-00002'})
        self.assertEqual(response.data['summary']['absent'], 1)

    def test_per_instructor_export_filters_by_instructor(self):
        response = self._export(mode='instructor', instructor_id=self.lts_instructor.id)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._student_ids(response), {'22-00002'})

    def test_per_day_export_filters_by_date(self):
        day = timezone.localtime(self.cwts_session.date_time).strftime('%Y-%m-%d')
        response = self._export(mode='day', date=day)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._student_ids(response), {'22-00001'})

    def test_per_day_export_excludes_other_days(self):
        day = timezone.localtime(self.lts_session.date_time).strftime('%Y-%m-%d')
        response = self._export(mode='day', date=day)
        self.assertEqual(self._student_ids(response), {'22-00002'})

    def test_custom_export_combines_filters(self):
        response = self._export(
            mode='custom',
            component='CWTS',
            instructor_id=self.cwts_instructor.id,
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._student_ids(response), {'22-00001'})

    def test_custom_export_without_filters_is_rejected(self):
        response = self._export(mode='custom')
        self.assertEqual(response.status_code, 400)

    def test_unknown_mode_is_rejected(self):
        response = self._export(mode='nonsense')
        self.assertEqual(response.status_code, 400)

    def test_malformed_date_is_rejected(self):
        response = self._export(mode='day', date='07-08-2026')
        self.assertEqual(response.status_code, 400)

    def test_absence_row_is_present_with_a_readable_remark(self):
        response = self._export(mode='program', component='LTS')
        row = response.data['records'][0]
        self.assertFalse(row['attended'])
        self.assertEqual(row['status'], 'Absent')
        self.assertIn('No time-in', row['remarks'])

    # ---------------------------------------------------------------
    # CSV export
    # ---------------------------------------------------------------

    def _csv_rows(self, response):
        return list(csv.reader(io.StringIO(response.content.decode('utf-8'))))

    def test_csv_is_a_downloadable_attachment(self):
        response = self._export(mode='program', component='CWTS', export='csv')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response['Content-Type'], 'text/csv')
        self.assertIn('attachment;', response['Content-Disposition'])
        self.assertIn('.csv', response['Content-Disposition'])

    def test_csv_header_identifies_the_class(self):
        response = self._export(mode='program', component='CWTS', export='csv')
        header = self._csv_rows(response)[0]
        self.assertEqual(header[0], 'Class')
        self.assertEqual(header[1], 'Program')
        self.assertEqual(header[2], 'Instructor')

    def test_csv_matches_the_json_rows(self):
        json_response = self._export(mode='program', component='CWTS')
        csv_response = self._export(
            mode='program', component='CWTS', export='csv'
        )

        json_ids = sorted(r['student_id'] for r in json_response.data['records'])
        csv_rows = self._csv_rows(csv_response)
        # Student ID is the 4th column in the campus layout.
        csv_ids = sorted(r[3] for r in csv_rows[1:] if r)
        self.assertEqual(json_ids, csv_ids)

    def test_csv_includes_the_absence(self):
        response = self._export(mode='program', component='LTS', export='csv')
        rows = self._csv_rows(response)
        status_col = rows[0].index('Status')
        values = [r[status_col] for r in rows[1:] if r]
        self.assertIn('Absent', values)
