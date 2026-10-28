"""Run against a disposable database with migrations 001–013 applied."""
import os
import subprocess
import time
import unittest


@unittest.skipUnless(os.environ.get("PROFILE_PIN_TEST_DB"), "needs disposable PostgreSQL database")
class ProfilePinRaceTest(unittest.TestCase):
    def setUp(self):
        self.command = ["psql", "-X", "-qAt", "-v", "ON_ERROR_STOP=1", "-d", os.environ["PROFILE_PIN_TEST_DB"]]
        self.run_sql("delete from sync_api.viewer_profiles where user_key = 'pin-race-owner';"
                     "insert into sync_api.viewer_profiles(user_key,profile_id,name) "
                     "values ('pin-race-owner','private','Race test');")

    def run_sql(self, sql):
        return subprocess.run(self.command, input=sql, text=True, capture_output=True, check=True).stdout

    def tearDown(self):
        self.run_sql("delete from sync_api.viewer_profiles where user_key = 'pin-race-owner';")

    def begin_session(self, sql):
        process = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        def close_session():
            if process.poll() is None:
                process.kill()
            process.communicate()
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()
        self.addCleanup(close_session)
        process.stdin.write("begin; set local role authenticated; "
                            "select set_config('request.jwt.claims', '{\"sub\":\"pin-race-owner\"}', true); "
                            + sql + "\n\\echo READY\n")
        process.stdin.flush()
        while True:
            line = process.stdout.readline()
            if line.strip() == "READY":
                return process
            if not line:
                self.fail(process.stderr.read())

    def wait_for_lock(self):
        for _ in range(100):
            waiting = self.run_sql("select count(*) from pg_stat_activity where application_name='pin-race-waiter' and wait_event_type='Lock';").strip()
            if waiting == "1":
                return
            time.sleep(0.05)
        self.fail("second transaction did not wait on the first")

    def test_setup_wins_and_waiting_delete_must_recheck_access(self):
        first = self.begin_session("select sync_api.profile_lock('set','private',null,'1234');")
        second = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True,
                                  env={**os.environ, "PGAPPNAME": "pin-race-waiter"})
        second.stdin.write("set role authenticated; select set_config('request.jwt.claims', "
                           "'{\"sub\":\"pin-race-owner\"}', false); "
                           "delete from sync_api.viewer_profiles where profile_id='private';")
        second.stdin.close()
        second.stdin = None
        self.wait_for_lock()
        first.stdin.write("commit;\n\\q\n")
        first.stdin.flush()
        self.assertEqual(first.wait(timeout=10), 0)
        _, error = second.communicate(timeout=10)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("Profile unlock required", error)
        self.assertEqual(self.run_sql("select count(*) from sync_api.viewer_profiles "
                                      "where user_key='pin-race-owner';").strip(), "1")

    def test_delete_wins_and_later_setup_cannot_leave_an_orphan(self):
        first = self.begin_session("delete from sync_api.viewer_profiles where profile_id='private';")
        second = subprocess.Popen(self.command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True,
                                  env={**os.environ, "PGAPPNAME": "pin-race-waiter"})
        second.stdin.write("set role authenticated; select set_config('request.jwt.claims', "
                           "'{\"sub\":\"pin-race-owner\"}', false); "
                           "select sync_api.profile_lock('set','private',null,'1234');")
        second.stdin.close()
        second.stdin = None
        self.wait_for_lock()
        first.stdin.write("commit;\n\\q\n")
        first.stdin.flush()
        self.assertEqual(first.wait(timeout=10), 0)
        output, error = second.communicate(timeout=10)
        self.assertEqual(second.returncode, 0, error)
        self.assertIn("profile_not_found", output)
        self.assertEqual(self.run_sql("select count(*) from sync_private.profile_pins "
                                      "where user_key='pin-race-owner';").strip(), "0")


if __name__ == "__main__":
    unittest.main()
