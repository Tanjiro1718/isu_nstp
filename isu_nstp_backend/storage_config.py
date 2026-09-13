"""Resolves the default Django storage backend from environment variables.

Keeping this out of settings.py makes the "is Supabase storage actually
configured?" decision a plain, testable function. The guard matters: a
half-configured S3/Supabase backend (for example ``USE_SUPABASE_STORAGE=true``
with an empty endpoint URL) makes every file write raise
``ValueError: Invalid endpoint:``, which previously rolled back registration
and returned a 500. If any required value is missing we deliberately fall back
to the local filesystem instead of crashing.
"""

import logging
import os

logger = logging.getLogger(__name__)

FILESYSTEM_STORAGE = 'django.core.files.storage.FileSystemStorage'
S3_STORAGE = 'storages.backends.s3.S3Storage'

# Every one of these must be present (non-empty) before we trust the S3
# backend. Access key/secret, bucket and endpoint are the minimum boto3 needs
# to build a working client.
REQUIRED_S3_ENV_VARS = (
    'SUPABASE_S3_ACCESS_KEY',
    'SUPABASE_S3_SECRET_KEY',
    'SUPABASE_S3_BUCKET',
    'SUPABASE_S3_ENDPOINT_URL',
)


def _is_true(value):
    return str(value or '').strip().lower() in ('true', '1', 'yes', 'on')


def resolve_default_storage(env=None):
    """Return the ``STORAGES['default']`` config for the given environment.

    *env* defaults to ``os.environ`` but is injectable so tests can exercise
    the guard without touching the real process environment.
    """
    env = os.environ if env is None else env

    if not _is_true(env.get('USE_SUPABASE_STORAGE')):
        return {'BACKEND': FILESYSTEM_STORAGE}

    missing = [
        name for name in REQUIRED_S3_ENV_VARS if not str(env.get(name) or '').strip()
    ]
    if missing:
        logger.warning(
            'USE_SUPABASE_STORAGE is enabled but %s missing; falling back to '
            'local FileSystemStorage. Uploaded files will not persist across '
            'deploys until this is fixed.',
            ', '.join(missing),
        )
        return {'BACKEND': FILESYSTEM_STORAGE}

    return {
        'BACKEND': S3_STORAGE,
        'OPTIONS': {
            'access_key': env.get('SUPABASE_S3_ACCESS_KEY', ''),
            'secret_key': env.get('SUPABASE_S3_SECRET_KEY', ''),
            'bucket_name': env.get('SUPABASE_S3_BUCKET', 'media'),
            'endpoint_url': env.get('SUPABASE_S3_ENDPOINT_URL', ''),
            'region_name': env.get('SUPABASE_S3_REGION', 'ap-southeast-1'),
            'file_overwrite': False,
            'querystring_auth': False,
            'default_acl': 'public-read',
        },
    }
