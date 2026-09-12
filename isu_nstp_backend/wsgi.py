"""
WSGI config for isu_nstp_backend project.

It exposes the WSGI callable as a module-level variable named ``application``.

For more information on this file, see
https://docs.djangoproject.com/en/5.2/howto/deployment/wsgi/
"""

import os
import sys

from django.core.wsgi import get_wsgi_application

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'isu_nstp_backend.settings')

_APPLICATION = None


def _ensure_schema():
    """Apply migrations on boot regardless of how gunicorn was started.

    Render invokes gunicorn directly and never runs entrypoint.sh, so the DB
    silently drifts behind the migrations (student login / admin list 500 on
    missing StudentProfile columns). flock serialises the gunicorn workers so
    they can't race each other's DDL; failures are logged and boot continues.
    """
    try:
        import django
        from django.core.management import call_command

        django.setup()
        lock = open(
            os.environ.get('MIGRATE_LOCK_FILE', '/tmp/isu_nstp_migrate.lock'),
            'w',
        )
        import fcntl
        fcntl.flock(lock, fcntl.LOCK_EX)
        call_command('migrate', interactive=False)
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()
    except Exception as exc:
        sys.stderr.write(f"WARNING: startup migration failed: {exc}\n")


def get_application():
    global _APPLICATION
    if _APPLICATION is None:
        _ensure_schema()
        _APPLICATION = get_wsgi_application()
    return _APPLICATION


application = get_application()
