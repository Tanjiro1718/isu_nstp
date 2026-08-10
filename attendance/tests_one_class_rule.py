"""
One-class-per-student rule: a student may only hold one active (or pending)
enrollment at a time, and can join a different class only after leaving their
current one.
"""

from django.test import TestCase
from rest_framework.test import APIClient

from .models import (
    ClassEnrollment,
    ClassGroup,
    StudentProfile,
    User,
)


class OneClassRuleTestBase(TestCase):
    def setUp(self):
        self.client = APIClient()

        self.instructor = User.objects.create_user(
            username='inst_one_class', password='Str0ngPass123', role='instructor'
        )
        self.class_a = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 1 - Sat AM',
            component='CWTS',
            section_code='CWTS-1A',
        )
        self.class_b = ClassGroup.objects.create(
            instructor=self.instructor,
            name='CWTS 2 - Sat PM',
            component='CWTS',
            section_code='CWTS-2B',
        )

        self.student_user = User.objects.create_user(
            username='one_class_student',
            password='Str0ngPass123',
            first_name='Solo',
            last_name='Reyes',
            role='student',
        )
        self.student_profile = StudentProfile.objects.create(
            user=self.student_user,
            student_id='22-33333',
            component='CWTS',
            section_code='CWTS-1A',
            course_and_section='BSIT 1A',
        )

    def _enroll(self, class_group, status='active'):
        return ClassEnrollment.objects.create(
            class_group=class_group,
            student=self.student_profile,
            status=status,
        )

    def _join_by_code(self, class_group):
        return self.client.post(
            '/api/classes/join/',
            {'join_code': class_group.join_code, 'student_id': self.student_user.id},
            format='json',
        )

    def _join_by_link(self, class_group):
        return self.client.post(
            '/api/classes/join-link/',
            {'invite_token': class_group.invite_token, 'student_id': self.student_user.id},
            format='json',
        )

    def _leave(self, class_group):
        return self.client.post(
            '/api/my-classes/leave/',
            {'student_id': self.student_user.id, 'class_id': class_group.id},
            format='json',
        )


class JoinBlockedWhileEnrolledTests(OneClassRuleTestBase):
    def test_join_by_code_refused_while_active_in_another_class(self):
        self._enroll(self.class_a)
        response = self._join_by_code(self.class_b)

        self.assertEqual(response.status_code, 403)
        self.assertIn('one class', response.data['error'].lower())

    def test_join_by_link_refused_while_active_in_another_class(self):
        self._enroll(self.class_a)
        response = self._join_by_link(self.class_b)

        self.assertEqual(response.status_code, 403)
        self.assertIn('one class', response.data['error'].lower())

    def test_join_refused_while_pending_in_another_class(self):
        self._enroll(self.class_a, status='pending')
        response = self._join_by_code(self.class_b)

        self.assertEqual(response.status_code, 403)

    def test_removed_enrollment_does_not_block_joining(self):
        self._enroll(self.class_a, status='removed')
        response = self._join_by_code(self.class_b)

        self.assertEqual(response.status_code, 201)


class LeaveAndRejoinTests(OneClassRuleTestBase):
    def test_leave_then_join_another_class(self):
        self._enroll(self.class_a)

        leave = self._leave(self.class_a)
        self.assertEqual(leave.status_code, 200)
        self.assertEqual(
            ClassEnrollment.objects.get(
                class_group=self.class_a, student=self.student_profile
            ).status,
            'removed',
        )

        join = self._join_by_code(self.class_b)
        self.assertEqual(join.status_code, 201)

    def test_rejoin_previously_left_class_when_free(self):
        self._enroll(self.class_a)
        self._leave(self.class_a)

        rejoin = self._join_by_code(self.class_a)
        self.assertEqual(rejoin.status_code, 200)
        self.assertEqual(
            ClassEnrollment.objects.get(
                class_group=self.class_a, student=self.student_profile
            ).status,
            'active',
        )

    def test_leave_unknown_class_returns_404(self):
        response = self.client.post(
            '/api/my-classes/leave/',
            {'student_id': self.student_user.id, 'class_id': 999999},
            format='json',
        )
        self.assertEqual(response.status_code, 404)

    def test_leave_requires_both_fields(self):
        response = self.client.post(
            '/api/my-classes/leave/',
            {'student_id': self.student_user.id},
            format='json',
        )
        self.assertEqual(response.status_code, 400)
