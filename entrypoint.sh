#!/bin/sh
set -e

# Restore the Firebase service account key when provided as an env var.
# Render does not let you upload files, so we pass the JSON content directly.
# Prefer FIREBASE_SERVICE_ACCOUNT_B64 (base64-encoded JSON): a single line,
# so it cannot be mangled by newline/paste formatting issues.
if [ -n "$FIREBASE_SERVICE_ACCOUNT_B64" ]; then
    echo "$FIREBASE_SERVICE_ACCOUNT_B64" | base64 -d > /app/serviceAccountKey.json
    echo "Firebase service account key written from FIREBASE_SERVICE_ACCOUNT_B64."
elif [ -n "$FIREBASE_SERVICE_ACCOUNT" ]; then
    echo "$FIREBASE_SERVICE_ACCOUNT" > /app/serviceAccountKey.json
    echo "Firebase service account key written from FIREBASE_SERVICE_ACCOUNT."
fi

# Run pending database migrations automatically on startup. This is
# unconditional so every deploy keeps the deployed schema in sync - the
# previous RUN_MIGRATIONS gate was never set on Render, so tables silently
# fell behind the migrations and login/serialization 500'd.
python manage.py migrate --noinput

# Collect static files (admin CSS etc.) into the staticfiles directory.
python manage.py collectstatic --noinput

exec gunicorn isu_nstp_backend.wsgi:application --bind 0.0.0.0:${PORT:-8000} --workers ${GUNICORN_WORKERS:-3} --timeout 120