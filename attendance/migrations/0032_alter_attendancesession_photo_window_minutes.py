# Lengthen the check-in photo window from 5 to 15 minutes.
#
# `photo_window_minutes` controls how long after `date_time` a student may
# still submit their time-in selfie (models.photo_deadline). The new window
# applies to every existing session too, so an in-progress activity already
# open when this ships gets the same 15 minutes a newly created one would.

from django.db import migrations, models


def extend_window(apps, schema_editor):
    AttendanceSession = apps.get_model('attendance', 'AttendanceSession')
    AttendanceSession.objects.filter(photo_window_minutes=5).update(photo_window_minutes=15)


def shrink_window(apps, schema_editor):
    AttendanceSession = apps.get_model('attendance', 'AttendanceSession')
    AttendanceSession.objects.filter(photo_window_minutes=15).update(photo_window_minutes=5)


class Migration(migrations.Migration):

    dependencies = [
        ('attendance', '0031_attendancerecord_uniq_attendance_record_per_session'),
    ]

    operations = [
        migrations.AlterField(
            model_name='attendancesession',
            name='photo_window_minutes',
            field=models.PositiveIntegerField(default=15),
        ),
        migrations.RunPython(extend_window, shrink_window),
    ]