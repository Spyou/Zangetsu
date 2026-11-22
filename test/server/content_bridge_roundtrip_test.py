"""Two-database round trip: a Supabase-shaped source and the VPS stage.

Mirrors the real bridge wiring — the source is read/written as postgres, the
stage as AniAura_bridge — so both replay guards are exercised.
"""

import os
import pathlib
import sys
import unittest
import uuid

import psycopg2

sys.path.insert(
    0, str(pathlib.Path(__file__).resolve().parents[2] / "server" / "sync")
)
from content_bridge import JOURNAL, TABLE_FIELDS, TABLE_KEYS
from library_bridge import (
    LibraryBridge,
    PostgresLibraryDatabase,
    PostgresLibraryState,
)


@unittest.skipUnless(
    os.environ.get("ZANGETSU_BRIDGE_INTEGRATION") == "1",
    "requires the two disposable bridge test databases",
)
class ContentBridgeRoundTripTest(unittest.TestCase):
    def test_edits_deletes_and_profile_rows_reach_both_sides(self):
        source_conn = psycopg2.connect(
            dbname="AniAura_sync_bridge_test", user="postgres"
        )
        vps_conn = psycopg2.connect(
            dbname="AniAura_sync_bridge_vps_test", user="AniAura_bridge"
        )
        self.addCleanup(source_conn.close)
        self.addCleanup(vps_conn.close)
        source = PostgresLibraryDatabase(
            source_conn, "supabase", JOURNAL, TABLE_KEYS, TABLE_FIELDS
        )
        vps = PostgresLibraryDatabase(
            vps_conn, "vps", JOURNAL, TABLE_KEYS, TABLE_FIELDS
        )
        bridge = LibraryBridge(source, vps, PostgresLibraryState(vps_conn, JOURNAL))
        user_key = f"content-roundtrip-{uuid.uuid4()}"

        with source_conn:
            with source_conn.cursor() as cursor:
                cursor.execute(
                    "insert into public.reading_history "
                    "(user_key, source_id, show_id, title, pos, total, "
                    "updated_ms, type) "
                    "values (%s, 'source', 'show', 'old', 1, 10, 100, 'manga')",
                    (user_key,),
                )
        self.assertTrue(bridge.process_once())
        with vps_conn.cursor() as cursor:
            cursor.execute(
                "select title from sync_api.reading_history where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], "old")
            cursor.execute(
                "select count(*) from sync_private.content_bridge_events "
                "where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)

        # A newer edit on the stage wins and is written back to the source.
        with vps_conn:
            with vps_conn.cursor() as cursor:
                cursor.execute(
                    "update sync_api.reading_history set title = 'new', "
                    "updated_ms = 200 where user_key = %s",
                    (user_key,),
                )
        self.assertTrue(bridge.process_once())
        with source_conn.cursor() as cursor:
            cursor.execute(
                "select title from public.reading_history where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], "new")

        # Profile-scoped reading rows carry their profile through both ways.
        with source_conn:
            with source_conn.cursor() as cursor:
                cursor.execute(
                    "insert into public.profile_reading_history "
                    "(user_key, profile_id, source_id, show_id, title, pos, "
                    "total, updated_ms, type) "
                    "values (%s, 'viewer', 'source', 'show', 'kids', 1, 10, "
                    "100, 'manga')",
                    (user_key,),
                )
        self.assertTrue(bridge.process_once())
        with vps_conn.cursor() as cursor:
            cursor.execute(
                "select title from sync_api.profile_reading_history "
                "where user_key = %s and profile_id = 'viewer'",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], "kids")

        # A viewer profile created by an old app version is mirrored.
        with source_conn:
            with source_conn.cursor() as cursor:
                cursor.execute(
                    "insert into public.viewer_profiles "
                    "(user_key, profile_id, name) values (%s, 'viewer', 'Viewer')",
                    (user_key,),
                )
        self.assertTrue(bridge.process_once())
        with vps_conn.cursor() as cursor:
            cursor.execute(
                "select name from sync_api.viewer_profiles "
                "where user_key = %s and profile_id = 'viewer'",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], "Viewer")

        # Deletes land on the other side and do not resurrect.
        with vps_conn.cursor() as cursor:
            cursor.execute(
                "select count(*) from sync_private.content_bridge_events "
                "where user_key = %s",
                (user_key,),
            )
            journal_before = cursor.fetchone()[0]
        with source_conn:
            with source_conn.cursor() as cursor:
                cursor.execute(
                    "delete from public.reading_history where user_key = %s",
                    (user_key,),
                )
        self.assertTrue(bridge.process_once())
        with vps_conn.cursor() as cursor:
            cursor.execute(
                "select count(*) from sync_api.reading_history "
                "where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)
            cursor.execute(
                "select count(*) from sync_private.content_bridge_events "
                "where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], journal_before)

        # Backups: one row per account, updated by upsert on either side.
        with vps_conn:
            with vps_conn.cursor() as cursor:
                cursor.execute(
                    "insert into sync_api.backups (user_key, payload) "
                    "values (%s, '{\"from\": \"app\"}')",
                    (user_key,),
                )
        self.assertTrue(bridge.process_once())
        with source_conn.cursor() as cursor:
            cursor.execute(
                "select payload from public.backups where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], '{"from": "app"}')
        with source_conn:
            with source_conn.cursor() as cursor:
                cursor.execute("delete from public.backups where user_key = %s", (user_key,))
        self.assertTrue(bridge.process_once())
        with vps_conn.cursor() as cursor:
            cursor.execute(
                "select count(*) from sync_api.backups where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
