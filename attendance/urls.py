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
    PresenceStatusAPIView,
    RespondPresenceCheckAPIView,
    CheckOutAPIView,
    OpenCheckOutAPIView,
    SessionPresenceRosterAPIView,
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
    
    # 4. Settings & Security
    path('system-settings/', SystemSettingsAPIView.as_view(), name='system-settings'),
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
    path('enrollments/<int:pk>/', ClassEnrollmentDetailAPIView.as_view(), name='enrollment-detail'),
    path('my-classes/', StudentClassListAPIView.as_view(), name='student-class-list'),

    # 6. Router endpoints (/users/)
    path('', include(router.urls)), 
]


