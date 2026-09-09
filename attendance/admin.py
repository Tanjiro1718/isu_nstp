from django.contrib import admin
from django.utils import timezone
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
    AccountDeletionRequest,
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


# ==========================================
# 5. ACCOUNT DELETION REQUESTS (Google Play data-safety)
# ==========================================
@admin.register(AccountDeletionRequest)
class AccountDeletionRequestAdmin(admin.ModelAdmin):
    list_display = ('email', 'user', 'status', 'requested_at', 'reviewed_at')
    search_fields = ('email', 'user__username', 'user__email')
    list_filter = ('status',)
    readonly_fields = ('email', 'user', 'reason', 'requested_at', 'reviewed_at')
    actions = ['delete_accounts', 'reject_requests']

    @admin.action(description='Delete selected accounts and all related data')
    def delete_accounts(self, request, queryset):
        from .fcm_utils import send_approval_notification
        from django.core.mail import EmailMultiAlternatives
        from django.conf import settings

        deleted = 0
        for deletion in queryset.filter(status='pending').select_related('user'):
            user = deletion.user
            fcm_token = user.push_token

            if fcm_token:
                try:
                    send_approval_notification(
                        fcm_token, is_approved=False, username=user.username
                    )
                except Exception as fcm_err:
                    print(f"⚠️ FCM failed for {user.username}: {fcm_err}")

            if user.email:
                try:
                    msg = EmailMultiAlternatives(
                        'Your account has been deleted - ISU NSTP Attendance',
                        (
                            f"Hello {user.get_full_name() or user.username},\n\n"
                            f"Your ISU NSTP Attendance account and the data "
                            f"associated with it have been deleted as requested.\n\n"
                            f"Attendance records that must be retained for "
                            f"institutional or legal purposes may remain on file "
                            f"in anonymized form.\n\n"
                            f"- ISU NSTP Support"
                        ),
                        getattr(settings, 'DEFAULT_FROM_EMAIL'),
                        [user.email],
                    )
                    msg.send()
                    print(f"✅ Deletion email sent to {user.email}")
                except Exception as email_err:
                    print(f"❌ Failed to send deletion email to {user.email}: {email_err}")

            deletion.status = 'deleted'
            deletion.reviewed_at = timezone.now()
            deletion.save(update_fields=['status', 'reviewed_at'])
            user.delete()
            deleted += 1

        self.message_user(
            request,
            f'{deleted} account(s) deleted. Cascading delete removed their '
            f'attendance records, enrollments, profiles, and related data.',
        )

    @admin.action(description='Reject selected deletion requests')
    def reject_requests(self, request, queryset):
        from django.core.mail import EmailMultiAlternatives
        from django.conf import settings

        rejected = 0
        for deletion in queryset.filter(status='pending').select_related('user'):
            user = deletion.user
            deletion.status = 'rejected'
            deletion.reviewed_at = timezone.now()
            deletion.save(update_fields=['status', 'reviewed_at'])
            rejected += 1

            if user.email:
                try:
                    msg = EmailMultiAlternatives(
                        'Your account deletion request - ISU NSTP Attendance',
                        (
                            f"Hello {user.get_full_name() or user.username},\n\n"
                            f"Your request to delete your ISU NSTP Attendance "
                            f"account could not be completed at this time.\n\n"
                            f"Please contact the NSTP office for assistance.\n\n"
                            f"- ISU NSTP Support"
                        ),
                        getattr(settings, 'DEFAULT_FROM_EMAIL'),
                        [user.email],
                    )
                    msg.send()
                except Exception as email_err:
                    print(f"❌ Failed to send rejection email to {user.email}: {email_err}")

        self.message_user(request, f'{rejected} deletion request(s) rejected.')


