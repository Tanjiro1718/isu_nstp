"""The storage guard must never let a half-configured Supabase/S3 backend
become the default, because an empty endpoint URL turns every upload into
``ValueError: Invalid endpoint:`` and previously 500'd registration.
"""

from django.test import SimpleTestCase

from isu_nstp_backend.storage_config import (
    FILESYSTEM_STORAGE,
    S3_STORAGE,
    resolve_default_storage,
)


class ResolveDefaultStorageTests(SimpleTestCase):
    def test_defaults_to_filesystem_when_supabase_disabled(self):
        config = resolve_default_storage({})
        self.assertEqual(config['BACKEND'], FILESYSTEM_STORAGE)

    def test_falls_back_to_filesystem_when_endpoint_missing(self):
        config = resolve_default_storage(
            {
                'USE_SUPABASE_STORAGE': 'true',
                'SUPABASE_S3_ACCESS_KEY': 'key',
                'SUPABASE_S3_SECRET_KEY': 'secret',
                'SUPABASE_S3_BUCKET': 'media',
                # SUPABASE_S3_ENDPOINT_URL intentionally absent
            }
        )
        self.assertEqual(config['BACKEND'], FILESYSTEM_STORAGE)

    def test_falls_back_when_any_required_value_is_blank(self):
        for blank in (
            'SUPABASE_S3_ACCESS_KEY',
            'SUPABASE_S3_SECRET_KEY',
            'SUPABASE_S3_BUCKET',
            'SUPABASE_S3_ENDPOINT_URL',
        ):
            env = {
                'USE_SUPABASE_STORAGE': 'true',
                'SUPABASE_S3_ACCESS_KEY': 'key',
                'SUPABASE_S3_SECRET_KEY': 'secret',
                'SUPABASE_S3_BUCKET': 'media',
                'SUPABASE_S3_ENDPOINT_URL': 'https://example.supabase.co/storage/v1/s3',
            }
            env[blank] = '   '
            with self.subTest(blank=blank):
                self.assertEqual(
                    resolve_default_storage(env)['BACKEND'], FILESYSTEM_STORAGE
                )

    def test_selects_s3_only_when_fully_configured(self):
        config = resolve_default_storage(
            {
                'USE_SUPABASE_STORAGE': 'true',
                'SUPABASE_S3_ACCESS_KEY': 'key',
                'SUPABASE_S3_SECRET_KEY': 'secret',
                'SUPABASE_S3_BUCKET': 'media',
                'SUPABASE_S3_ENDPOINT_URL': 'https://example.supabase.co/storage/v1/s3',
                'SUPABASE_S3_REGION': 'ap-southeast-1',
            }
        )
        self.assertEqual(config['BACKEND'], S3_STORAGE)
        self.assertEqual(
            config['OPTIONS']['endpoint_url'],
            'https://example.supabase.co/storage/v1/s3',
        )
        self.assertEqual(config['OPTIONS']['bucket_name'], 'media')
        self.assertFalse(config['OPTIONS']['querystring_auth'])
