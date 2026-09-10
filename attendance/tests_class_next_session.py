"""
The instructor class list must tell the instructor, at a glance, whether a
session has been created for that class: the ClassGroupSerializer exposes the
next upcoming session (never a past/ended one) as `next_session`.
"""

from datetime import timedelta

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from .models import AttendanceSession, ClassGroup, User

TARGET_LAT = '16.9303'
TARGET_LNG = '121.7667'


class ClassNextSessionTests(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.instructor = User.objects.create_user(
            username='sess_instructor',
            email='sess_instructor@isu.edu.ph',
            password='Str0ngPass123',
            role='instructor',
        )
        self.class_group = ClassGroup.objects.create(
            name='CWTS 1A',
            component='CWTS',
            section_code='1A',
            instructor=self.instructor,
        )
        self.list_url = f'/api/classes/?instructor_id={self.instructor.id}'

    def _session(self, days_from_now, title='CWTS 1A Attendance'):
        return AttendanceSession.objects.create(
            instructor=self.instructor,
            class_group=self.class_group,
            title=title,
            date_time=timezone.now() + timedelta(days=days_from_now),
            target_latitude=TARGET_LAT,
            target_longitude=TARGET_LNG,
            radius_meters=50,
        )

    def _first_class(self):
        response = self.client.get(self.list_url)
        self.assertEqual(response.status_code, 200, response.content)
        payload = response.json()
        self.assertEqual(len(payload), 1)
        return payload[0]

    def test_class_without_session_has_null_next_session(self):
        self.assertIsNone(self._first_class()['next_session'])

    def test_future_session_is_exposed(self):
        session = self._session(days_from_now=1)

        next_session = self._first_class()['next_session']
        self.assertIsNotNone(next_session)
        self.assertEqual(next_session['id'], session.id)
        self.assertEqual(next_session['title'], session.title)
        # date_time round-trips to a parseable ISO timestamp.
        self.assertTrue(next_session['date_time'].endswith('+00:00') or next_session['date_time'].endswith('Z'))

    def test_past_session_is_ignored(self):
        self._session(days_from_now=-1)

        self.assertIsNone(self._first_class()['next_session'])

    def test_earliest_future_session_wins(self):
        sooner = self._session(days_from_now=1, title='This one')
        self._session(days_from_now=3, title='Later one')

        next_session = self._first_class()['next_session']
        self.assertEqual(next_session['id'], sooner.id)