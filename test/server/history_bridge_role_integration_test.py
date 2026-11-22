"""Run as AniAura_bridge on a disposable VPS test database."""

import os
import pathlib
import sys
import unittest
import uuid
from datetime import datetime, timezone

import psycopg2

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "server" / "sync"))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from history_bridge import HistoryEvent, PostgresHistoryDatabase


@unittest.skipUnless(
    os.environ.get("ZANGETSU_BRIDGE_ROLE_INTEGRATION") == "1",
    "requires disposable VPS database and bridge OS user",
)
class BridgeRoleIntegrationTest(unittest.TestCase):
    def test_replay_can_replace_an_older_progress_timestamp_without_echo(self):
        connection = psycopg2.connect(
            dbname="AniAura_sync_bridge_vps_test", user="AniAura_bridge"
        )
        self.addCleanup(connection.close)
        database = PostgresHistoryDatabase(connection, "vps")
        user_key = f"bridge-role-{uuid.uuid4()}"

        def replay(updated_at, title, operation="upsert"):
            payload = {
                "user_key": user_key,
                "source_id": "source",
                "show_id": "show",
                "show_title": title,
                "position_ms": 0,
                "duration_ms": 0,
                "updated_at": updated_at,
            }
            database.apply(
                HistoryEvent(
                    "supabase", updated_at, user_key, None, "source", "show",
                    operation, None if operation == "delete" else payload,
                    datetime.now(timezone.utc),
                )
            )

        replay(200, "first")
        replay(100, "central winner")
        with connection.cursor() as cursor:
            cursor.execute(
                "select show_title from sync_api.history where user_key = %s", (user_key,)
            )
            self.assertEqual(cursor.fetchone()[0], "central winner")
            cursor.execute(
                "select count(*) from sync_private.history_bridge_events "
                "where user_key = %s", (user_key,)
            )
            self.assertEqual(cursor.fetchone()[0], 0)
        replay(300, "", operation="delete")


if __name__ == "__main__":
    unittest.main()
