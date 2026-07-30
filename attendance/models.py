from django.db import models
from django.contrib.auth.models import AbstractUser
from django.utils import timezone
import datetime
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
    title = models.CharField(max_length=100) # e.g., Barangay Tree Planting
    date_time = models.DateTimeField()
    target_latitude = models.DecimalField(max_digits=9, decimal_places=6)  # Geofence target
    target_longitude = models.DecimalField(max_digits=9, decimal_places=6) # Geofence target
    radius_meters = models.IntegerField(default=50) # Allowed check-in radius

    def __str__(self):
        return f"{self.title} ({self.date_time.strftime('%Y-%m-%d')})"


# 5. Attendance Ledger mapped to Students
class AttendanceRecord(models.Model):
    STATUS_CHOICES = (('Present', 'Present'), ('Absent', 'Absent'), ('Late', 'Late'))
    MODE_CHOICES = (('online', 'Online'), ('offline', 'Offline'))
    
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

    def __str__(self):
        return f"{self.student.student_id} - {self.session.title} [{self.status}]"


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

class PendingApproval(StudentProfile):
    class Meta:
        proxy = True  # Tells Django NOT to create a new database table
        verbose_name = 'Pending Approval'
        verbose_name_plural = 'Pending Approvals'