from django.db import models
from django.contrib.auth.models import AbstractUser
from django.utils import timezone
import datetime
import random
import secrets

# Random "are you still on site?" pings land this far apart. The instructor
# never sets an exact time, so a student cannot predict the next prompt.
PRESENCE_GAP_MIN_MINUTES = 20
PRESENCE_GAP_MAX_MINUTES = 40
# Quiet period after a ping before the next one may be scheduled. Without this
# two pings could land 20 minutes apart and feel like harassment.
PRESENCE_COOLDOWN_MINUTES = 60
# Every activity runs for a fixed 4 hours; instructors don't choose this.
SESSION_DURATION_MINUTES = 240

from django.dispatch import receiver
from django.db.models.signals import post_save
from django.contrib.auth.models import User
from django.contrib.auth import get_user_model

# 1. Custom User Model to differentiate the 4 distinct roles
class User(AbstractUser):
    ROLE_CHOICES = (
        ('student', 'Student'),
        ('instructor', 'Instructor'),
        ('director', 'NSTP Director'),
        ('admin', 'System Admin'),
    )
    role = models.CharField(max_length=20, choices=ROLE_CHOICES, default='student') # Made optional for initial registration
    phone_number = models.CharField(max_length=15, blank=True, null=True)

    # first_name / last_name come from AbstractUser; only the middle name is extra.
    middle_name = models.CharField(max_length=150, blank=True, null=True)

    # Device token for push notifications. Lives on User (not StudentProfile)
    # so instructors, directors, and admins can be notified too.
    fcm_token = models.CharField(max_length=512, blank=True, null=True)

    @property
    def push_token(self):
        """
        Best available device token.

        Students registered before this field existed still have their token on
        StudentProfile, so fall back to it rather than losing their push.
        """
        if self.fcm_token:
            return self.fcm_token
        profile = getattr(self, 'student_profile', None)
        return getattr(profile, 'fcm_token', None) if profile else None

    def get_full_name(self):
        """First + Middle + Last, skipping any blanks.

        Overrides AbstractUser.get_full_name() so the middle name is included
        everywhere a full name is already displayed.
        """
        parts = [self.first_name, self.middle_name, self.last_name]
        return ' '.join(p.strip() for p in parts if p and p.strip())


# 2. Instructor Details
class InstructorProfile(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE, limit_choices_to={'role': 'instructor'})
    department = models.CharField(max_length=50) # e.g., ROTC, CWTS, LTS

    def __str__(self):
        return f"Instructor: {self.user.get_full_name() or self.user.username}"


# 3. Student Profile containing their specific NSTP configuration & registration status
class StudentProfile(models.Model):
    COMPONENT_CHOICES = (
        ('CWTS', 'CWTS'),
        ('LTS', 'LTS'),
        ('ROTC', 'ROTC'),
    )

    user = models.OneToOneField(
        User,
        on_delete=models.CASCADE,
        related_name='student_profile',
        limit_choices_to={'role': 'student'}
    )
    # Made null=True & blank=True to prevent database crashes during initial signal creation
    student_id = models.CharField(max_length=20, unique=True, null=True, blank=True) # e.g., 21-12345
    course_and_section = models.CharField(max_length=100, blank=True, null=True) # e.g., BSIT-NS 1A

    # Assigned by admin/director later or optional during registration
    component = models.CharField(max_length=10, choices=COMPONENT_CHOICES, blank=True, null=True)
    section_code = models.CharField(max_length=20, blank=True, null=True) # e.g., CWTS-1A

    # --- Registration Verification & Approval Status ---
    id_picture_front = models.ImageField(upload_to='student_ids/', blank=True, null=True)
    is_email_verified = models.BooleanField(default=False)
    is_approved_by_admin = models.BooleanField(default=False)

    # --- Push Notifications ---
    fcm_token = models.CharField(max_length=512, blank=True, null=True)

    def __str__(self):
        display_id = self.student_id or self.user.username
        return f"Student: {display_id} - {self.course_and_section or 'Unassigned'}"


# 4. Attendance Session created by Instructors
class AttendanceSession(models.Model):
    instructor = models.ForeignKey(User, on_delete=models.CASCADE, limit_choices_to={'role': 'instructor'})
    class_group = models.ForeignKey('ClassGroup', on_delete=models.CASCADE, related_name='attendance_sessions', null=True, blank=True)
    title = models.CharField(max_length=100) # e.g., Barangay Tree Planting
    date_time = models.DateTimeField()
    target_latitude = models.DecimalField(max_digits=9, decimal_places=6)  # Geofence target
    target_longitude = models.DecimalField(max_digits=9, decimal_places=6) # Geofence target
    radius_meters = models.IntegerField(default=50) # Allowed check-in radius

    # --- Presence verification rules ---
    # How long after the session opens a student may still submit their selfie.
    photo_window_minutes = models.PositiveIntegerField(default=5)
    # Fixed 4-hour activity length. Set by the server, not the instructor, so
    # the presence schedule below always has a predictable window to fill.
    duration_minutes = models.PositiveIntegerField(
        default=SESSION_DURATION_MINUTES
    )
    # How many random "are you still there?" pings each student receives.
    presence_check_count = models.PositiveIntegerField(default=2)
    # How long a student has to answer one ping before it counts as missed.
    presence_response_minutes = models.PositiveIntegerField(default=5)

    # --- Instructor-controlled time-out ---
    # Students stay on standby after timing in; nobody may submit a time-out
    # photo until the instructor opens the window from Monitor Headcounts.
    is_check_out_open = models.BooleanField(default=False)
    check_out_opened_at = models.DateTimeField(blank=True, null=True)

    @property
    def photo_deadline(self):
        """Last moment a check-in selfie is accepted."""
        return self.date_time + datetime.timedelta(minutes=self.photo_window_minutes)

    @property
    def ends_at(self):
        return self.date_time + datetime.timedelta(minutes=self.duration_minutes)

    def __str__(self):
        return f"{self.title} ({self.date_time.strftime('%Y-%m-%d')})"


# 5. Attendance Ledger mapped to Students
class AttendanceRecord(models.Model):
    STATUS_CHOICES = (('Present', 'Present'), ('Absent', 'Absent'), ('Late', 'Late'))
    MODE_CHOICES = (('online', 'Online'), ('offline', 'Offline'))
    PRESENCE_STATUS_CHOICES = (
        ('ok', 'Verified Present'),
        ('warned', 'Warned - Missed A Check'),
        ('failed', 'Failed Verification'),
    )

    session = models.ForeignKey(AttendanceSession, on_delete=models.CASCADE)
    student = models.ForeignKey(StudentProfile, on_delete=models.CASCADE)
    timestamp = models.DateTimeField(auto_now_add=True)
    student_latitude = models.DecimalField(max_digits=9, decimal_places=6)
    student_longitude = models.DecimalField(max_digits=9, decimal_places=6)
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='Absent')
    mode = models.CharField(max_length=10, choices=MODE_CHOICES, default='online')
    student_address = models.CharField(max_length=255, blank=True, null=True)
    selfie_verified = models.BooleanField(default=False)
    selfie_image = models.ImageField(upload_to='attendance/selfies/', blank=True, null=True)

    # --- Random presence verification ---
    presence_status = models.CharField(
        max_length=10, choices=PRESENCE_STATUS_CHOICES, default='ok'
    )
    missed_checks = models.PositiveIntegerField(default=0)

    # --- Time out (check-out) ---
    check_out_at = models.DateTimeField(blank=True, null=True)
    check_out_latitude = models.DecimalField(max_digits=9, decimal_places=6, blank=True, null=True)
    check_out_longitude = models.DecimalField(max_digits=9, decimal_places=6, blank=True, null=True)
    check_out_selfie = models.ImageField(upload_to='attendance/checkout/', blank=True, null=True)

    @property
    def can_check_out(self):
        """
        Time-out needs three things: the instructor has opened the window, the
        student answered their presence pings, and they have not already left.
        """
        return (
            self.session.is_check_out_open
            and self.presence_status != 'failed'
            and self.check_out_at is None
        )

    def schedule_presence_checks(self):
        """
        Drops randomly timed pings into the remaining session window.

        Called right after a successful check-in. The first ping lands a random
        20-40 minutes after time-in. Every ping after that waits out a 1 hour
        cooldown first, then adds another random 20-40 minutes - so the student
        can never predict (or share) the exact moment, but is also never pinged
        twice in quick succession.

        With the default 4 hour window that puts ping 1 at 20-40 minutes and
        ping 2 at 100-140 minutes after time-in.
        """
        session = self.session
        count = session.presence_check_count
        if count <= 0:
            return []

        now = timezone.now()
        window_end = session.ends_at
        # Leave room at the end so the final ping can still be answered.
        window_end -= datetime.timedelta(minutes=session.presence_response_minutes)

        checks = []
        moment = now
        for i in range(count):
            # The cooldown applies between pings, not before the first one.
            if i > 0:
                moment += datetime.timedelta(minutes=PRESENCE_COOLDOWN_MINUTES)

            gap = random.randint(PRESENCE_GAP_MIN_MINUTES, PRESENCE_GAP_MAX_MINUTES)
            moment += datetime.timedelta(minutes=gap)
            # A short activity just gets fewer pings, rather than ones that
            # would fire after everybody has already gone home.
            if moment > window_end:
                break
            checks.append(
                PresenceCheck(record=self, scheduled_at=moment, sequence=i + 1)
            )

        return PresenceCheck.objects.bulk_create(checks)

    def __str__(self):
        return f"{self.student.student_id} - {self.session.title} [{self.status}]"


# 5b. Random "are you still on site?" prompts tied to one attendance record
class PresenceCheck(models.Model):
    STATUS_CHOICES = (
        ('pending', 'Scheduled'),
        ('sent', 'Awaiting Response'),
        ('responded', 'Responded'),
        ('missed', 'Missed'),
    )

    record = models.ForeignKey(
        AttendanceRecord, on_delete=models.CASCADE, related_name='presence_checks'
    )
    sequence = models.PositiveIntegerField(default=1)
    scheduled_at = models.DateTimeField()
    sent_at = models.DateTimeField(blank=True, null=True)
    expires_at = models.DateTimeField(blank=True, null=True)
    responded_at = models.DateTimeField(blank=True, null=True)
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='pending')

    # Where the student was when they answered.
    response_latitude = models.DecimalField(max_digits=9, decimal_places=6, blank=True, null=True)
    response_longitude = models.DecimalField(max_digits=9, decimal_places=6, blank=True, null=True)
    was_warning = models.BooleanField(default=False)

    class Meta:
        ordering = ['scheduled_at']

    @property
    def is_open(self):
        """Still awaiting an answer and not yet expired."""
        return (
            self.status == 'sent'
            and self.expires_at is not None
            and timezone.now() < self.expires_at
        )

    def seconds_remaining(self):
        if not self.is_open:
            return 0
        return max(0, int((self.expires_at - timezone.now()).total_seconds()))

    def __str__(self):
        return f"Check #{self.sequence} for {self.record.student.student_id} [{self.status}]"


# 6. System Settings for global configurations
class SystemSettings(models.Model):
    target_latitude = models.FloatField(default=16.9240)
    target_longitude = models.FloatField(default=121.7516)
    allowed_radius_meters = models.IntegerField(default=100)
    academic_year = models.CharField(max_length=20, default="2026-2027")
    semester = models.CharField(max_length=20, default="1st Semester")

    class Meta:
        verbose_name = "System Settings"
        verbose_name_plural = "System Settings"

    def __str__(self):
        return f"Settings: Radius {self.allowed_radius_meters}m ({self.academic_year})"

class OTPVerification(models.Model):
    email = models.EmailField(unique=True)
    code = models.CharField(max_length=6)
    created_at = models.DateTimeField(auto_now=True)

    def is_valid(self):
        # Code is valid for 10 minutes
        return timezone.now() - self.created_at < datetime.timedelta(minutes=10)

    def __str__(self):
        return f"{self.email} - {self.code}"


class PasswordResetCode(models.Model):
    """
    Temporary password reset verification codes sent via push notification.
    Separate from OTPVerification to avoid conflicts with registration flow.
    """
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='password_reset_codes')
    code = models.CharField(max_length=6)
    created_at = models.DateTimeField(auto_now_add=True)

    def is_valid(self):
        """Code expires after 10 minutes."""
        return timezone.now() - self.created_at < datetime.timedelta(minutes=10)

    def __str__(self):
        return f"{self.user.email} - {self.code} (expires {self.created_at + datetime.timedelta(minutes=10)})"

class PendingApproval(StudentProfile):
    class Meta:
        proxy = True  # Tells Django NOT to create a new database table
        verbose_name = 'Pending Approval'
        verbose_name_plural = 'Pending Approvals'


# 7. Class Group (Google Classroom style) created by Instructors
# Ambiguous characters (0/O, 1/I/L) are excluded so codes are easy to read aloud.
JOIN_CODE_ALPHABET = 'abcdefghjkmnpqrstuvwxyz23456789'


def generate_join_code(length=7):
    """Human friendly class code, e.g. 'k4mq7zx'."""
    return ''.join(secrets.choice(JOIN_CODE_ALPHABET) for _ in range(length))


def generate_invite_token():
    """Unguessable token used inside the shareable invitation link."""
    return secrets.token_urlsafe(24)


class ClassGroup(models.Model):
    COMPONENT_CHOICES = StudentProfile.COMPONENT_CHOICES

    instructor = models.ForeignKey(
        User,
        on_delete=models.CASCADE,
        related_name='class_groups',
        limit_choices_to={'role': 'instructor'},
    )
    name = models.CharField(max_length=100)  # e.g. CWTS 1 - Saturday AM
    component = models.CharField(max_length=10, choices=COMPONENT_CHOICES, blank=True, null=True)
    section_code = models.CharField(max_length=20, blank=True, null=True)
    description = models.CharField(max_length=255, blank=True, null=True)

    # --- Join credentials ---
    join_code = models.CharField(max_length=12, unique=True, db_index=True)
    invite_token = models.CharField(max_length=64, unique=True, db_index=True)

    # Instructor can freeze joining without deleting the class
    is_join_enabled = models.BooleanField(default=True)
    requires_approval = models.BooleanField(default=False)

    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ['-created_at']

    def save(self, *args, **kwargs):
        if not self.join_code:
            self.join_code = self._unique_value('join_code', generate_join_code)
        if not self.invite_token:
            self.invite_token = self._unique_value('invite_token', generate_invite_token)
        super().save(*args, **kwargs)

    @staticmethod
    def _unique_value(field, generator):
        for _ in range(20):
            value = generator()
            if not ClassGroup.objects.filter(**{field: value}).exists():
                return value
        raise RuntimeError(f'Unable to generate a unique {field}')

    def rotate_join_code(self):
        self.join_code = self._unique_value('join_code', generate_join_code)
        self.save(update_fields=['join_code'])
        return self.join_code

    def rotate_invite_token(self):
        self.invite_token = self._unique_value('invite_token', generate_invite_token)
        self.save(update_fields=['invite_token'])
        return self.invite_token

    @property
    def student_count(self):
        return self.enrollments.filter(status='active').count()

    def __str__(self):
        return f"{self.name} [{self.join_code}]"


# 8. Enrollment ledger linking students to a ClassGroup
class ClassEnrollment(models.Model):
    STATUS_CHOICES = (
        ('active', 'Active'),
        ('pending', 'Pending Approval'),
        ('removed', 'Removed'),
    )
    JOIN_METHOD_CHOICES = (
        ('code', 'Join Code'),
        ('link', 'Invitation Link'),
        ('manual', 'Added by Instructor'),
    )

    class_group = models.ForeignKey(ClassGroup, on_delete=models.CASCADE, related_name='enrollments')
    student = models.ForeignKey(StudentProfile, on_delete=models.CASCADE, related_name='class_enrollments')
    status = models.CharField(max_length=10, choices=STATUS_CHOICES, default='active')
    join_method = models.CharField(max_length=10, choices=JOIN_METHOD_CHOICES, default='code')
    joined_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        unique_together = ('class_group', 'student')
        ordering = ['-joined_at']

    def __str__(self):
        return f"{self.student} -> {self.class_group.name} [{self.status}]"


