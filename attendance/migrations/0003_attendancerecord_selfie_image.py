from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('attendance', '0002_systemsettings'),
    ]

    operations = [
        migrations.AddField(
            model_name='attendancerecord',
            name='selfie_image',
            field=models.ImageField(blank=True, null=True, upload_to='attendance/selfies/'),
        ),
    ]
