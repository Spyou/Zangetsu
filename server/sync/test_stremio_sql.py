"""Run against an isolated database named stremio_test_* after migration 014."""
import json
import os
import subprocess
import unittest


@unittest.skipUnless(os.environ.get('STREMIO_TEST_DB', '').startswith('stremio_test_'),
                     'isolated PostgreSQL database not configured')
class StremioSqlTest(unittest.TestCase):
    def run_sql(self, sql, owner='stremio-test-a', success=True):
        prefix = "set role authenticated; set request.jwt.claims = '" + json.dumps({'sub': owner}) + "'; "
        result = subprocess.run(['psql', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1',
            '-d', os.environ['STREMIO_TEST_DB'], '-c', prefix + sql], capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        return result.stderr

    def test_compare_and_swap_keeps_the_newer_configuration(self):
        first = self.run_sql("select sync_api.stremio_configuration();", owner='stremio-cas')
        version = first['version']
        saved = self.run_sql("select sync_api.stremio_configuration(" + str(version) +
            ", '{\"format\":\"stremio-server-v1\",\"ciphertext\":\"test-only\"}');", owner='stremio-cas')
        self.assertTrue(saved['accepted'])
        stale = self.run_sql("select sync_api.stremio_configuration(" + str(version) +
            ", '{\"format\":\"stremio-server-v1\",\"ciphertext\":\"stale\"}');", owner='stremio-cas')
        self.assertFalse(stale['accepted'])
        self.assertEqual(stale['payload'], saved['payload'])

    def test_other_account_cannot_read_the_saved_configuration(self):
        value = self.run_sql('select sync_api.stremio_configuration();', owner='stremio-other-account')
        self.assertIsNone(value['payload'])

    def test_tables_cannot_be_accessed_directly(self):
        self.assertIn('permission denied', self.run_sql(
            'select * from sync_private.stremio_configurations;', success=False))

    def test_missing_owner_and_plaintext_payload_are_rejected(self):
        self.run_sql('select sync_api.stremio_configuration();', owner='', success=False)
        self.run_sql("select sync_api.stremio_configuration(0, '{\"plaintext\":\"not allowed\"}');", success=False)


if __name__ == '__main__':
    unittest.main()
