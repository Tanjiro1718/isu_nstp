from django.db import models
from django.contrib.auth.models import AbstractUser

# 1. Custom User Model to differentiate the 4 distinct roles
class User(AbstractUser):
    ROLE_CHOICES = (
        ('student', 'Student'),
        ('instructor', 'Instructor'),
        ('director', 'NSTP Director'),
        ('admin', 'System Admin'),
    )
    CAMPUS_CHOICES = (
        ('echague', 'Echague (Main)'),
        ('cauayan', 'Cauayan'),
        ('ilagan', 'Ilagan'),
        ('cabagan', 'Cabagan'),
    )
    role = models.CharField(max_length=20, choices=ROLE_CHOICES, default='student')
    campus = models.CharField(max_length=30, choices=CAMPUS_CHOICES)
    phone_number = models.CharField(max_length=15, blank=True, null=True)

# 2. Instructor Details
class InstructorProfile(models.Model):
    user = models.OneToOneField(User, on_delete=models.CASCADE, limit_choices_to={'role': 'instructor'})
    department = models.CharField(max_length=50) # e.g., ROTC, CWTS, LTS

# 3. Student Profile containing their specific NSTP configuration
class StudentProfile(models.Model):
    COMPONENT_CHOICES = (('CWTS', 'CWTS'), ('LTS', 'LTS'), ('ROTC', 'ROTC'))
    
    user = models.OneToOneField(User, on_delete=models.CASCADE, limit_choices_to={'role': 'student'})
    student_id = models.CharField(max_length=20, unique=True) # e.g., 23-12345
    component = models.CharField(max_length=10, choices=COMPONENT_CHOICES)
    section_code = models.CharField(max_length=20) # e.g., CWTS-1A

# 4. Attendance Session created by Instructors
class AttendanceSession(models.Model):
    instructor = models.ForeignKey(User, on_delete=models.CASCADE, limit_choices_to={'role': 'instructor'})
    title = models.CharField(max_length=100) # e.g., Barangay Tree Planting
    date_time = models.DateTimeField()
    target_latitude = models.DecimalField(max_digits=9, decimal_places=6)  # Geofence target
    target_longitude = models.DecimalField(max_digits=9, decimal_places=6) # Geofence target
    radius_meters = models.IntegerField(default=50) # Allowed check-in radius

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