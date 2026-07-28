from django.urls import path, include
from .views import LoginAPIView, ProcessCheckInAPI, AttendanceLogAPIView, AttendanceSessionAPIView
from .views import UserViewSet
from rest_framework.routers import DefaultRouter
from .views import SystemSettingsAPIView
from .views import PasswordResetAPIView

# The router automatically creates /api/users/ and /api/users/<id>/ for deleting
router = DefaultRouter()
router.register(r'users', UserViewSet, basename='user')

urlpatterns = [
    path('login/', LoginAPIView.as_view(), name='api-login'),
    path('attendance/check-in/', ProcessCheckInAPI.as_view(), name='api-checkin'),
    path('attendance/logs/', AttendanceLogAPIView.as_view(), name='api-attendance-logs'),
    path('attendance/session/current/', AttendanceSessionAPIView.as_view(), name='api-current-session'),
    path('system-settings/', SystemSettingsAPIView.as_view(), name='system-settings'),
    path('password-reset/', PasswordResetAPIView.as_view(), name='api-password-reset'),
    # Changed 'api/' to '' (empty string) so it doesn't double up!
    path('', include(router.urls)), 
]
