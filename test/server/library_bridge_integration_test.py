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
from library_bridge import LibraryEvent, PostgresLibraryDatabase


@unittest.skipUnless(
    os.environ.get("ZANGETSU_LIBRARY_BRIDGE_INTEGRATION") == "1",
    "requires disposable VPS database and bridge OS user",
)
class LibraryBridgeIntegrationTest(unittest.TestCase):
    def test_list_category_assignment_and_delete_do_not_echo(self):
        connection = psycopg2.connect(
            dbname="AniAura_sync_bridge_vps_test", user="AniAura_bridge"
        )
        self.addCleanup(connection.close)
        database = PostgresLibraryDatabase(connection, "vps")
        user_key = f"library-bridge-{uuid.uuid4()}"
        category_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc)

        def event(table, key, row=None):
            return LibraryEvent(
                "supabase", 1, table, user_key, "", key,
                "upsert" if row is not None else "delete", row, now,
            )

        item_key = {"source_id": "source", "item_id": "item"}
        database.apply(event("mylist", item_key, {
            "user_key": user_key, **item_key, "title": "Test",
            "cover_headers": {"Referer": "https://example.test"},
            "added_at": 0,
            "sync_id": 999, "sync_version": 999,
        }))
        database.apply(event("list_categories", {"id": category_id}, {
            "id": category_id, "user_key": user_key, "name": "Favorites",
            "position": 0, "created_at": now.isoformat(),
        }))
        assignment = {**item_key, "category_id": category_id}
        database.apply(event("mylist_categories", assignment, {
            "user_key": user_key, **assignment,
        }))
        with connection.cursor() as cursor:
            cursor.execute(
                "select title, sync_id, sync_version, cover_headers "
                "from sync_api.mylist where user_key = %s", (user_key,)
            )
            title, sync_id, sync_version, headers = cursor.fetchone()
            self.assertEqual(title, "Test")
            self.assertNotEqual(sync_id, 999)
            self.assertEqual(sync_version, 1)
            self.assertEqual(headers["Referer"], "https://example.test")
            cursor.execute(
                "select count(*) from sync_api.mylist_categories where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 1)
        database.apply(event("mylist", item_key))
        database.apply(event("list_categories", {"id": category_id}))
        with connection.cursor() as cursor:
            cursor.execute(
                "select count(*) from sync_private.library_bridge_events "
                "where user_key = %s", (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)
            cursor.execute(
                "select count(*) from sync_api.mylist_categories where user_key = %s",
                (user_key,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)


if __name__ == "__main__":
    unittest.main()
