from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):

    dependencies = [
        ('attendance', '0011_classgroup_classenrollment'),
    ]

    operations = [
        migrations.AddField(
            model_name='attendancesession',
            name='class_group',
            field=models.ForeignKey(
                blank=True,
                null=True,
                on_delete=django.db.models.deletion.CASCADE,
                related_name='attendance_sessions',
                to='attendance.classgroup',
            ),
        ),
    ]
