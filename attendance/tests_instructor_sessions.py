"""
"Instructor sessions" list - the data behind the My Sessions screen.

An instructor should be able to see every session they created (upcoming,
running, and done), with a quick sense of how many students timed in, and
never see another instructor's sessions.
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


class InstructorSessionsTests(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.instructor = User.objects.create_user(
            username='inst_sessions', password='Str0ngPass123', role='instructor'
        )
        self.other_instructor = User.objects.create_user(
            username='inst_other', password='Str0ngPass123', role='instructor'
        )

        self.class_group = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 1 - Sat AM',
            component='CWTS',
            section_code='CWTS-1A',
        )
        self.other_class = ClassGroup.objects.create(
            instructor=self.other_instructor,
            name='ROTC 1 - Sun AM',
            component='ROTC',
            section_code='ROTC-1A',
        )

        self.student_a = self._enroll(self.class_group, '22-10001', 'Ana', 'Reyes')
        self.student_b = self._enroll(self.class_group, '22-10002', 'Ben', 'Cruz')

        self.past = self._session(self.class_group, 'Past', timezone.now() - timedelta(days=2))
        self.ongoing = self._session(self.class_group, 'Ongoing', timezone.now() - timedelta(hours=1))
        self.upcoming = self._session(self.class_group, 'Upcoming', timezone.now() + timedelta(days=1))
        self.foreign = self._session(self.other_class, 'Other Instructor', timezone.now() - timedelta(days=1))

    def _enroll(self, class_group, student_id, first, last):
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
            component=class_group.component or '',
            section_code=class_group.section_code or '',
            course_and_section='BSIT 1A',
        )
        ClassEnrollment.objects.create(
            class_group=class_group, student=profile, status='active'
        )
        return profile

    def _session(self, class_group, title, when):
        return AttendanceSession.objects.create(
            instructor=class_group.instructor,
            class_group=class_group,
            title=title,
            date_time=when,
            target_latitude=17.0,
            target_longitude=121.0,
            radius_meters=100,
        )

    def _list(self, instructor_id=None):
        instructor_id = instructor_id if instructor_id is not None else self.instructor.id
        return self.client.get(f'/api/instructor/sessions/?instructor_id={instructor_id}')

    # ------------------------------------------------------------------
    # Ownership
    # ------------------------------------------------------------------

    def test_only_own_sessions_are_returned(self):
        response = self._list()
        self.assertEqual(response.status_code, 200)

        titles = {s['title'] for s in response.data['sessions']}
        self.assertEqual(titles, {'Past', 'Ongoing', 'Upcoming'})
        self.assertNotIn('Other Instructor', titles)

    def test_instructor_without_classes_gets_an_empty_list(self):
        loner = User.objects.create_user(
            username='inst_loner', password='Str0ngPass123', role='instructor'
        )
        response = self._list(loner.id)

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data['sessions'], [])

    def test_missing_instructor_id_is_rejected(self):
        response = self.client.get('/api/instructor/sessions/')
        self.assertEqual(response.status_code, 400)

    # ------------------------------------------------------------------
    # Status classification
    # ------------------------------------------------------------------

    def test_sessions_are_classified_by_time(self):
        response = self._list()
        by_title = {s['title']: s for s in response.data['sessions']}

        self.assertEqual(by_title['Past']['status'], 'Completed')
        self.assertEqual(by_title['Ongoing']['status'], 'Ongoing')
        self.assertEqual(by_title['Upcoming']['status'], 'Upcoming')

    # ------------------------------------------------------------------
    # Attendance context
    # ------------------------------------------------------------------

    def test_checked_in_and_expected_counts(self):
        AttendanceRecord.objects.create(
            session=self.past,
            student=self.student_a,
            student_latitude=17.0,
            student_longitude=121.0,
            status='Present',
        )

        response = self._list()
        by_title = {s['title']: s for s in response.data['sessions']}

        past = by_title['Past']
        self.assertEqual(past['expected'], 2)
        self.assertEqual(past['checked_in'], 1)
        self.assertEqual(past['attendance_rate'], 50.0)

        upcoming = by_title['Upcoming']
        self.assertEqual(upcoming['expected'], 2)
        self.assertEqual(upcoming['checked_in'], 0)
