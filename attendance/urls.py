from django.urls import path, include
from rest_framework.routers import DefaultRouter

# Updated RegisterAPIView -> RegisterView to match views.py
from .views import (
    LoginAPIView,
    RegisterView,  
    ProcessCheckInAPI,
    AttendanceLogAPIView,
    AttendanceSessionAPIView,
    UserViewSet,
    SystemSettingsAPIView,
    PasswordResetAPIView,
    RequestPasswordResetCodeAPIView,
    ConfirmPasswordResetAPIView,
    RequestChangePasswordCodeAPIView,
    ConfirmChangePasswordAPIView,
    RegisterDeviceTokenAPIView,
    SendVerificationCodeAPIView,
    VerifyOTPAPIView,
    ClassGroupListCreateAPIView,
    ClassGroupDetailAPIView,
    RotateJoinCodeAPIView,
    JoinClassByCodeAPIView,
    JoinClassByLinkAPIView,
    ClassEnrollmentDetailAPIView,
    InvitePreviewAPIView,
    StudentClassListAPIView,
    StudentLeaveClassAPIView,
    PresenceStatusAPIView,
    RespondPresenceCheckAPIView,
    CheckOutAPIView,
    OpenCheckOutAPIView,
    SessionPresenceRosterAPIView,
    DirectorOverviewAPIView,
    DirectorClassSessionsAPIView,
    StudentAttendanceHistoryAPIView,
    ClassAttendanceDatesAPIView,
    ClassAttendanceRecordsAPIView,
    StudentExcuseAPIView,
    InstructorExcuseListAPIView,
    ReviewExcuseAPIView,
)


router = DefaultRouter()
router.register(r'users', UserViewSet, basename='user')

urlpatterns = [
    # 1. Registration endpoint (matches RegisterView)
    path('register/', RegisterView.as_view(), name='api-register'),
    
    # 2. Login endpoint
    path('login/', LoginAPIView.as_view(), name='api-login'),
    
    # 3. Attendance endpoints
    path('attendance/check-in/', ProcessCheckInAPI.as_view(), name='api-checkin'),
    path('attendance/logs/', AttendanceLogAPIView.as_view(), name='api-attendance-logs'),
    path('attendance/session/current/', AttendanceSessionAPIView.as_view(), name='api-current-session'),
    path('attendance/check-out/', CheckOutAPIView.as_view(), name='api-checkout'),
    path('attendance/presence/status/', PresenceStatusAPIView.as_view(), name='api-presence-status'),
    path('attendance/presence/respond/', RespondPresenceCheckAPIView.as_view(), name='api-presence-respond'),
    path('attendance/check-out/open/', OpenCheckOutAPIView.as_view(), name='api-open-checkout'),
    path('attendance/session/roster/', SessionPresenceRosterAPIView.as_view(), name='api-session-roster'),
    # Student-facing history: every session they were expected at.
    path('attendance/my-history/', StudentAttendanceHistoryAPIView.as_view(), name='api-my-attendance-history'),

    # --- Director oversight ---
    path('director/overview/', DirectorOverviewAPIView.as_view(), name='api-director-overview'),
    path('director/classes/<int:pk>/sessions/', DirectorClassSessionsAPIView.as_view(), name='api-director-class-sessions'),
    
    # 4. Settings & Security
    path('system-settings/', SystemSettingsAPIView.as_view(), name='system-settings'),
    # Forgot password: request a code (push + email), then confirm it.
    path('password-reset/request-code/', RequestPasswordResetCodeAPIView.as_view(), name='api-password-reset-request-code'),
    path('password-reset/confirm/', ConfirmPasswordResetAPIView.as_view(), name='api-password-reset-confirm'),
    # In-app change password (Profile screen): needs the current password.
    path('change-password/request-code/', RequestChangePasswordCodeAPIView.as_view(), name='api-change-password-request-code'),
    path('change-password/confirm/', ConfirmChangePasswordAPIView.as_view(), name='api-change-password-confirm'),
    # Lets any role register its device so pushes reach them.
    path('device-token/', RegisterDeviceTokenAPIView.as_view(), name='api-device-token'),
    # Legacy temp-password reset, kept for older app builds.
    path('password-reset/', PasswordResetAPIView.as_view(), name='api-password-reset'),
    path('send-code/', SendVerificationCodeAPIView.as_view(), name='send-verification-code'),
    path('verify-code/', VerifyOTPAPIView.as_view(), name='verify-verification-code'),

    # 5. Class Groups (Google Classroom style invites)
    path('classes/', ClassGroupListCreateAPIView.as_view(), name='class-list-create'),
    path('classes/<int:pk>/', ClassGroupDetailAPIView.as_view(), name='class-detail'),
    path('classes/<int:pk>/rotate-code/', RotateJoinCodeAPIView.as_view(), name='class-rotate-code'),
    path('classes/join/', JoinClassByCodeAPIView.as_view(), name='class-join-by-code'),
    path('classes/join-link/', JoinClassByLinkAPIView.as_view(), name='class-join-by-link'),
    path('classes/invite/<str:token>/', InvitePreviewAPIView.as_view(), name='class-invite-preview'),
    # Class attendance record: which days have data, then the rows for a day.
    # Append ?format=csv to the second one to download it as a spreadsheet.
    path('classes/<int:pk>/attendance-dates/', ClassAttendanceDatesAPIView.as_view(), name='class-attendance-dates'),
    path('classes/<int:pk>/attendance-records/', ClassAttendanceRecordsAPIView.as_view(), name='class-attendance-records'),
    path('enrollments/<int:pk>/', ClassEnrollmentDetailAPIView.as_view(), name='enrollment-detail'),

    # Excuse letters: student files one, instructor rules on it.
    path('excuses/', StudentExcuseAPIView.as_view(), name='student-excuses'),
    path('excuses/review-queue/', InstructorExcuseListAPIView.as_view(), name='instructor-excuses'),
    path('excuses/<int:pk>/review/', ReviewExcuseAPIView.as_view(), name='review-excuse'),
    path('my-classes/', StudentClassListAPIView.as_view(), name='student-class-list'),
    path('my-classes/leave/', StudentLeaveClassAPIView.as_view(), name='student-class-leave'),

    # 6. Router endpoints (/users/)
    path('', include(router.urls)), 
]


