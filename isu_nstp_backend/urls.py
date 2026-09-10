"""
URL configuration for isu_nstp_backend project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/5.2/topics/http/urls/
Examples:
Function views
    1. Add an import:  from my_app import views
    2. Add a URL to urlpatterns:  path('', views.home, name='home')
Class-based views
    1. Add an import:  from other_app.views import Home
    2. Add a URL to urlpatterns:  path('', Home.as_view(), name='home')
Including another URLconf
    1. Import the include() function: from django.urls import include, path
    2. Add a URL to urlpatterns:  path('blog/', include('blog.urls'))
"""
from django.contrib import admin
from django.urls import path, include, re_path
from rest_framework.routers import DefaultRouter
from attendance.views import UserViewSet, invite_landing_page
from django.conf import settings
from attendance.views import privacy_policy, account_deletion_page, terms_and_conditions
from django.views.static import serve


router = DefaultRouter()
router.register(r'users', UserViewSet, basename='user')

urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/', include('attendance.urls')),
    path("privacy-policy/", privacy_policy, name="privacy_policy"),
    path("terms-conditions/", terms_and_conditions, name="terms_and_conditions"),
    # Account deletion URL required by the Google Play data-safety form.
    path("account-deletion/", account_deletion_page, name="account_deletion"),

    # Shareable class invitation link (opened in a browser by students)
    path('join/<str:token>/', invite_landing_page, name='invite-landing'),
]


# Serves uploaded ID images (student IDs, selfies, excuses) whenever they live
# on the local filesystem - development AND production, since Django only adds
# the media route automatically under DEBUG. Skipped once Supabase Storage is
# enabled (STORAGES['default'] switches to S3), where image URLs are absolute
# Supabase object URLs that never touch /media/.
if settings.STORAGES['default'].get('BACKEND') == 'django.core.files.storage.FileSystemStorage':
    urlpatterns += [re_path(r'^media/(?P<path>.*)$', serve, {'document_root': settings.MEDIA_ROOT})]