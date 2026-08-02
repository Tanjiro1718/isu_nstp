from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        ('attendance', '0012_attendancesession_class_group'),
    ]

    operations = [
        migrations.AddField(
            model_name='user',
            name='middle_name',
            field=models.CharField(blank=True, max_length=150, null=True),
        ),
    ]
