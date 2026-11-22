"""Run as the postgres OS user against the two disposable bridge test DBs."""

import pathlib
import os
import sys
import unittest
import uuid

import psycopg2

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "server" / "sync"))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from history_bridge import HistoryBridge, PostgresBridgeState, PostgresHistoryDatabase


@unittest.skipUnless(
    os.environ.get("ZANGETSU_BRIDGE_INTEGRATION") == "1",
    "requires disposable VPS databases",
)
class HistoryBridgeIntegrationTest(unittest.TestCase):
    def test_upsert_edit_delete_and_no_echo(self):
        source_conn = psycopg2.connect(dbname="AniAura_sync_bridge_test", user="postgres")
        vps_conn = psycopg2.connect(dbname="AniAura_sync_bridge_vps_test", user="postgres")
        self.addCleanup(source_conn.close)
        self.addCleanup(vps_conn.close)
        source = PostgresHistoryDatabase(source_conn, "supabase")
        vps = PostgresHistoryDatabase(vps_conn, "vps")
        bridge = HistoryBridge(source, vps, PostgresBridgeState(vps_conn))
        user_key = f"bridge-integration-{uuid.uuid4()}"

        with source_conn:
            with source_conn.cursor() as cursor:
                cursor.execute(
                    "insert into public.history "
                    "(user_key, source_id, show_id, show_title, updated_at) "
                    "values (%s, 'source', 'show', 'old', 100)",
                    (user_key,),
                )
        self.assertTrue(bridge.process_once())
        with vps_conn.cursor() as cursor:
            cursor.execute(
                "select show_title from sync_api.history where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], "old")
            cursor.execute(
                "select count(*) from sync_private.history_bridge_events "
                "where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)

        with vps_conn:
            with vps_conn.cursor() as cursor:
                cursor.execute(
                    "update sync_api.history set show_title = 'new', updated_at = 200 "
                    "where user_key = %s",
                    (user_key,),
                )
        self.assertTrue(bridge.process_once())
        with source_conn.cursor() as cursor:
            cursor.execute(
                "select show_title from public.history where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], "new")

        with source_conn:
            with source_conn.cursor() as cursor:
                cursor.execute("delete from public.history where user_key = %s", (user_key,))
        self.assertTrue(bridge.process_once())
        with vps_conn.cursor() as cursor:
            cursor.execute("select count(*) from sync_api.history where user_key = %s", (user_key,))
            self.assertEqual(cursor.fetchone()[0], 0)

    def test_profile_history_stays_in_its_own_table(self):
        source_conn = psycopg2.connect(dbname="AniAura_sync_bridge_test", user="postgres")
        vps_conn = psycopg2.connect(dbname="AniAura_sync_bridge_vps_test", user="postgres")
        self.addCleanup(source_conn.close)
        self.addCleanup(vps_conn.close)
        source = PostgresHistoryDatabase(source_conn, "supabase")
        bridge = HistoryBridge(
            source, PostgresHistoryDatabase(vps_conn, "vps"), PostgresBridgeState(vps_conn)
        )
        user_key = f"bridge-profile-{uuid.uuid4()}"
        with source_conn:
            with source_conn.cursor() as cursor:
                cursor.execute(
                    "insert into public.profile_history "
                    "(user_key, profile_id, source_id, show_id, updated_at) "
                    "values (%s, 'child', 'source', 'show', 100)",
                    (user_key,),
                )
        self.assertTrue(bridge.process_once())
        with vps_conn.cursor() as cursor:
            cursor.execute(
                "select count(*) from sync_api.profile_history "
                "where user_key = %s and profile_id = 'child'",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 1)
            cursor.execute(
                "select count(*) from sync_api.history where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)

        source.prune_processed(bridge.state.cursor("supabase"), retain=0)
        with source_conn.cursor() as cursor:
            cursor.execute(
                "select count(*) from sync_private.history_bridge_events "
                "where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)
            cursor.execute(
                "select count(*) from public.profile_history where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 1)

if __name__ == "__main__":
    unittest.main()
