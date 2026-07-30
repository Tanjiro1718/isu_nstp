from django.contrib import admin
from .models import User, AttendanceSession, AttendanceRecord, StudentProfile, OTPVerification, PendingApproval

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
# Other basic registrations
# ==========================================
admin.site.register(AttendanceSession)
admin.site.register(AttendanceRecord)
admin.site.register(OTPVerification)