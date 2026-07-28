from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('attendance', '0003_attendancerecord_selfie_image'),
    ]

    operations = [
        migrations.AddField(
            model_name='attendancerecord',
            name='mode',
            field=models.CharField(choices=[('online', 'Online'), ('offline', 'Offline')], default='online', max_length=10),
        ),
        migrations.AddField(
            model_name='attendancerecord',
            name='student_address',
            field=models.CharField(blank=True, max_length=255, null=True),
        ),
    ]