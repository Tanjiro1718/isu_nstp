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
    
    # 4. Settings & Security
    path('system-settings/', SystemSettingsAPIView.as_view(), name='system-settings'),
    path('password-reset/', PasswordResetAPIView.as_view(), name='api-password-reset'),
    path('send-code/', SendVerificationCodeAPIView.as_view(), name='send-verification-code'),
    path('verify-code/', VerifyOTPAPIView.as_view(), name='verify-verification-code'),
    
    # 5. Router endpoints (/users/)
    path('', include(router.urls)), 
]