from django.contrib import admin
from .models import (
    User,
    AttendanceSession,
    AttendanceRecord,
    PresenceCheck,
    StudentProfile,
    OTPVerification,
    PendingApproval,
    ClassGroup,
    ClassEnrollment,
)


# ==========================================
# 1. USERS LIST: Show ONLY Approved (Active) Users
# ==========================================
@admin.register(User)
class CustomUserAdmin(admin.ModelAdmin):
    list_display = ('username', 'email', 'is_active')
    search_fields = ('username', 'email')
    
    def get_queryset(self, request):
        qs = super().get_queryset(request)
        return qs.filter(is_active=True)  # Hides pending accounts

# ==========================================
# 2. STUDENT PROFILES: Show ONLY Approved Students
# ==========================================
@admin.register(StudentProfile)
class StudentProfileAdmin(admin.ModelAdmin):
    list_display = ('user', 'course_and_section', 'is_approved_by_admin')
    search_fields = ('user__username', 'course_and_section')

    def get_queryset(self, request):
        qs = super().get_queryset(request)
        return qs.filter(is_approved_by_admin=True) # Hides pending accounts

# ==========================================
# 3. PENDING APPROVALS: The Waiting Room
# ==========================================
@admin.register(PendingApproval)
class PendingApprovalAdmin(admin.ModelAdmin):
    list_display = ('user', 'course_and_section', 'is_approved_by_admin')
    search_fields = ('user__username', 'course_and_section')
    
    def get_queryset(self, request):
        qs = super().get_queryset(request)
        return qs.exclude(is_approved_by_admin=True) # Shows ONLY pending accounts

    def save_model(self, request, obj, form, change):
        # Auto-activates the user so they can log in to Flutter!
        if obj.is_approved_by_admin:
            obj.user.is_active = True
            obj.user.save()
        super().save_model(request, obj, form, change)

# ==========================================
# 4. CLASS GROUPS
# ==========================================
@admin.register(ClassGroup)
class ClassGroupAdmin(admin.ModelAdmin):
    list_display = ('name', 'instructor', 'join_code', 'component', 'is_join_enabled', 'created_at')
    search_fields = ('name', 'join_code', 'instructor__username')
    list_filter = ('component', 'is_join_enabled', 'requires_approval')
    readonly_fields = ('join_code', 'invite_token', 'created_at')


@admin.register(ClassEnrollment)
class ClassEnrollmentAdmin(admin.ModelAdmin):
    list_display = ('student', 'class_group', 'status', 'join_method', 'joined_at')
    search_fields = ('student__student_id', 'class_group__name')
    list_filter = ('status', 'join_method')


# ==========================================
# Other basic registrations
# ==========================================
admin.site.register(AttendanceSession)
admin.site.register(AttendanceRecord)
admin.site.register(OTPVerification)


@admin.register(PresenceCheck)
class PresenceCheckAdmin(admin.ModelAdmin):
    """Lets staff audit who was pinged, when, and who ignored it."""
    list_display = ('record', 'sequence', 'status', 'scheduled_at', 'sent_at', 'responded_at')
    list_filter = ('status', 'was_warning')
    search_fields = ('record__student__student_id',)


