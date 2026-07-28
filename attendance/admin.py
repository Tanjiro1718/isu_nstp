from django.contrib import admin
from .models import User, AttendanceSession, AttendanceRecord

# Register your models here.
admin.site.register(User)
admin.site.register(AttendanceSession)
admin.site.register(AttendanceRecord)