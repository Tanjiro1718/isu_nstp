#!/bin/sh
set -e

# Restore the Firebase service account key when provided as an env var.
# Render does not let you upload files, so we pass the JSON content directly.
if [ -n "$FIREBASE_SERVICE_ACCOUNT" ]; then
    echo "$FIREBASE_SERVICE_ACCOUNT" > /app/serviceAccountKey.json
    echo "Firebase service account key written from FIREBASE_SERVICE_ACCOUNT."
fi

# Run pending database migrations automatically on startup.
if [ "$RUN_MIGRATIONS" = "true" ]; then
    python manage.py migrate --noinput
fi

# Collect static files (admin CSS etc.) into the staticfiles directory.
python manage.py collectstatic --noinput

exec gunicorn isu_nstp_backend.wsgi:application --bind 0.0.0.0:${PORT:-8000} --workers ${GUNICORN_WORKERS:-3} --timeout 120