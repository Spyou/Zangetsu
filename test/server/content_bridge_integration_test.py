"""Run as AniAura_bridge against its disposable VPS test database."""

import os
import pathlib
import sys
import unittest
import uuid
from datetime import datetime, timezone

import psycopg2

test_path = pathlib.Path(__file__).resolve()
sys.path.insert(0, str(
    test_path.parents[2] / "server" / "sync"
    if len(test_path.parents) > 2 else pathlib.Path("/opt/AniAura-sync")
))
from content_bridge import JOURNAL, TABLE_FIELDS, TABLE_KEYS
from library_bridge import LibraryEvent, PostgresLibraryDatabase


@unittest.skipUnless(
    os.environ.get("ZANGETSU_CONTENT_BRIDGE_INTEGRATION") == "1",
    "requires disposable VPS database and bridge OS user",
)
class ContentBridgeIntegrationTest(unittest.TestCase):
    def test_reading_profile_and_backup_replay_does_not_echo(self):
        connection = psycopg2.connect(
            dbname="AniAura_sync_bridge_vps_test", user="AniAura_bridge"
        )
        self.addCleanup(connection.close)
        database = PostgresLibraryDatabase(
            connection, "vps", JOURNAL, TABLE_KEYS, TABLE_FIELDS
        )
        user_key = f"content-bridge-{uuid.uuid4()}"
        now = datetime.now(timezone.utc)

        def event(table, key, row=None, scope=""):
            return LibraryEvent(
                "supabase", 1, table, user_key, scope, key,
                "upsert" if row is not None else "delete", row, now,
            )

        show_key = {"source_id": "source", "show_id": "show"}
        database.apply(event("reading_history", show_key, {
            "user_key": user_key, **show_key, "title": "Test", "cover": None,
            "chapter_id": "chapter", "chapter_number": 3.5,
            "chapter_url": "https://x/chapter", "pos": 2, "total": 20,
            "updated_ms": 7, "type": "manga",
        }))
        database.apply(event("viewer_profiles", {"profile_id": "viewer"}, {
            "user_key": user_key, "profile_id": "viewer", "name": "Viewer",
            "avatar": 1, "is_kids": False, "created_at": now.isoformat(),
            "photo_url": None,
        }))
        database.apply(event("profile_reading_history", show_key, {
            "user_key": user_key, "profile_id": "viewer", **show_key,
            "title": "Test", "cover": None, "chapter_id": "chapter",
            "chapter_number": 3.5, "chapter_url": "https://x/chapter",
            "pos": 2, "total": 20, "updated_ms": 7, "type": "manga",
        }, scope="viewer"))
        database.apply(event("backups", {}, {
            "user_key": user_key, "payload": '{"settings": true}',
            "updated_at": now.isoformat(),
        }))

        with connection.cursor() as cursor:
            cursor.execute(
                "select title, pos, total from sync_api.reading_history "
                "where user_key = %s", (user_key,)
            )
            self.assertEqual(cursor.fetchone(), ("Test", 2, 20))
            cursor.execute(
                "select name, avatar from sync_api.viewer_profiles "
                "where user_key = %s", (user_key,)
            )
            self.assertEqual(cursor.fetchone(), ("Viewer", 1))
            cursor.execute(
                "select count(*) from sync_api.profile_reading_history "
                "where user_key = %s", (user_key,)
            )
            self.assertEqual(cursor.fetchone()[0], 1)
            cursor.execute(
                "select payload from sync_api.backups where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], '{"settings": true}')

        database.apply(event("reading_history", show_key))
        database.apply(event("viewer_profiles", {"profile_id": "viewer"}))
        database.apply(event("backups", {}))
        with connection.cursor() as cursor:
            cursor.execute(
                "select count(*) from sync_private.content_bridge_events "
                "where user_key = %s", (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)
            cursor.execute(
                "select count(*) from sync_api.reading_history "
                "where user_key = %s", (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)
            cursor.execute(
                "select count(*) from sync_api.viewer_profiles "
                "where user_key = %s", (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)
            cursor.execute(
                "select count(*) from sync_api.backups where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
