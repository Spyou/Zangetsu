"""Temporary My List/category bridge for old and new app versions."""

from dataclasses import dataclass
from datetime import datetime
import json
import os
import sys
import time

from history_bridge import load_source_dsn, source_connection_kwargs


TABLE_KEYS = {
    "mylist": ("user_key", "source_id", "item_id"),
    "profile_mylist": ("user_key", "profile_id", "source_id", "item_id"),
    "list_categories": ("id",),
    "profile_list_categories": ("user_key", "profile_id", "id"),
    "mylist_categories": ("user_key", "source_id", "item_id", "category_id"),
    "profile_mylist_categories": (
        "user_key", "profile_id", "source_id", "item_id", "category_id"
    ),
}
TABLE_FIELDS = {
    "mylist": (
        "user_key", "source_id", "item_id", "title", "cover", "cover_headers",
        "url", "type", "status", "added_at",
    ),
    "profile_mylist": (
        "user_key", "profile_id", "source_id", "item_id", "title", "cover",
        "cover_headers", "url", "type", "status", "added_at",
    ),
    "list_categories": ("id", "user_key", "name", "position", "created_at"),
    "profile_list_categories": ("user_key", "profile_id", "id", "name", "position"),
    "mylist_categories": ("user_key", "source_id", "item_id", "category_id"),
    "profile_mylist_categories": (
        "user_key", "profile_id", "source_id", "item_id", "category_id"
    ),
}


@dataclass(frozen=True)
class LibraryEvent:
    origin: str
    id: int
    table_name: str
    user_key: str
    profile_scope: str
    key_data: dict
    operation: str
    row_data: dict | None
    changed_at: datetime

    @property
    def key(self):
        return (
            self.table_name, self.user_key, self.profile_scope,
            json.dumps(self.key_data, sort_keys=True, separators=(",", ":")),
        )


class LibraryBridge:
    def __init__(self, source, vps, state):
        self.source = source
        self.vps = vps
        self.state = state

    def process_once(self):
        candidates = [
            event for event in (
                self.source.next_event(self.state.cursor("supabase")),
                self.vps.next_event(self.state.cursor("vps")),
            ) if event is not None
        ]
        if not candidates:
            return False
        event = min(candidates, key=lambda item: (item.changed_at, item.origin, item.id))
        previous = self.state.latest(event.key)
        winner = event
        if previous is not None and (
            previous.changed_at, previous.origin, previous.id
        ) > (event.changed_at, event.origin, event.id):
            winner = previous
        self.source.apply(winner)
        self.vps.apply(winner)
        self.state.commit(event, winner)
        return True


class PostgresLibraryDatabase:
    def __init__(
        self, connection, origin, journal="library_bridge",
        table_keys=TABLE_KEYS, table_fields=TABLE_FIELDS,
    ):
        if origin not in ("supabase", "vps"):
            raise ValueError("unknown library origin")
        self.connection = connection
        self.origin = origin
        self.journal = journal
        self.table_keys = table_keys
        self.table_fields = table_fields
        self.schema = "public" if origin == "supabase" else "sync_api"

    def next_event(self, after_id):
        with self.connection.cursor() as cursor:
            cursor.execute(
                "select id, table_name, user_key, profile_scope, key_data, "
                "operation, row_data, changed_at "
                f"from sync_private.{self.journal}_events "
                "where id > %s order by id limit 1",
                (after_id,),
            )
            row = cursor.fetchone()
        return LibraryEvent(self.origin, *row) if row else None

    def apply(self, event):
        if event.table_name not in self.table_fields or event.operation not in ("upsert", "delete"):
            raise ValueError("unknown library event")
        table = f"{self.schema}.{event.table_name}"
        key_values = {"user_key": event.user_key, **event.key_data}
        if event.table_name.startswith("profile_"):
            key_values["profile_id"] = event.profile_scope
        if event.operation == "upsert":
            row = event.row_data
            if row is None or any(row.get(key) != value for key, value in key_values.items()):
                raise ValueError("library event identity does not match its row")
        keys = self.table_keys[event.table_name]
        with self.connection:
            with self.connection.cursor() as cursor:
                cursor.execute("set local AniAura.bridge_replay = 'on'")
                if event.operation == "delete":
                    filters = " and ".join(f"{key} = %s" for key in keys)
                    cursor.execute(
                        f"delete from {table} where {filters}",
                        tuple(key_values[key] for key in keys),
                    )
                    return
                fields = self.table_fields[event.table_name]
                columns = ", ".join(fields)
                updates = [field for field in fields if field not in keys]
                conflict = ", ".join(keys)
                action = (
                    "do update set " + ", ".join(
                        f"{field} = excluded.{field}" for field in updates
                    ) if updates else "do nothing"
                )
                cursor.execute(
                    f"insert into {table} ({columns}) "
                    f"select {columns} from jsonb_populate_record("
                    f"null::{table}, %s::jsonb) where true "
                    f"on conflict ({conflict}) {action}",
                    (json.dumps(event.row_data),),
                )

    def prune_processed(self, through_id, retain=100):
        cutoff = through_id - retain
        if cutoff <= 0:
            return 0
        with self.connection:
            with self.connection.cursor() as cursor:
                cursor.execute(
                    f"delete from sync_private.{self.journal}_events where id in ("
                    f"select id from sync_private.{self.journal}_events "
                    "where id <= %s order by id limit 1000)",
                    (cutoff,),
                )
                return cursor.rowcount


class PostgresLibraryState:
    def __init__(self, connection, journal="library_bridge"):
        self.connection = connection
        self.journal = journal

    def cursor(self, origin):
        with self.connection.cursor() as cursor:
            cursor.execute(
                "select last_id from "
                f"sync_private.{self.journal}_cursors "
                "where origin = %s", (origin,),
            )
            row = cursor.fetchone()
        return row[0] if row else 0

    def latest(self, key):
        with self.connection.cursor() as cursor:
            cursor.execute(
                "select origin, event_id, operation, row_data, changed_at "
                f"from sync_private.{self.journal}_latest "
                "where table_name = %s and user_key = %s and profile_scope = %s "
                "and key_text = %s", key,
            )
            row = cursor.fetchone()
        return LibraryEvent(row[0], row[1], *key[:3], json.loads(key[3]),
                            row[2], row[3], row[4]) if row else None

    def commit(self, processed, winner):
        with self.connection:
            with self.connection.cursor() as cursor:
                cursor.execute(
                    "insert into "
                    f"sync_private.{self.journal}_latest "
                    "(table_name, user_key, profile_scope, key_text, origin, "
                    "event_id, operation, row_data, changed_at) "
                    "values (%s,%s,%s,%s,%s,%s,%s,%s::jsonb,%s) "
                    "on conflict (table_name, user_key, profile_scope, key_text) "
                    "do update set origin = excluded.origin, "
                    "event_id = excluded.event_id, operation = excluded.operation, "
                    "row_data = excluded.row_data, changed_at = excluded.changed_at",
                    (*winner.key, winner.origin, winner.id, winner.operation,
                     json.dumps(winner.row_data), winner.changed_at),
                )
                cursor.execute(
                    "insert into "
                    f"sync_private.{self.journal}_cursors (origin, last_id) "
                    "values (%s, %s) on conflict (origin) do update "
                    "set last_id = greatest("
                    f"sync_private.{self.journal}_cursors.last_id, "
                    "excluded.last_id)",
                    (processed.origin, processed.id),
                )


def main():
    import psycopg2

    source = psycopg2.connect(
        **source_connection_kwargs(load_source_dsn(os.environ["SUPABASE_DSN_FILE"])),
        sslmode="require", connect_timeout=10,
    )
    try:
        vps = psycopg2.connect(os.environ["VPS_DSN"], connect_timeout=10)
        try:
            with vps.cursor() as cursor:
                cursor.execute("select pg_try_advisory_lock(%s)", (238903481230916,))
                if not cursor.fetchone()[0]:
                    return
            bridge = LibraryBridge(
                PostgresLibraryDatabase(source, "supabase"),
                PostgresLibraryDatabase(vps, "vps"),
                PostgresLibraryState(vps),
            )
            processed = 0
            while True:
                if bridge.process_once():
                    processed += 1
                    if processed >= 1000:
                        bridge.source.prune_processed(bridge.state.cursor("supabase"))
                        bridge.vps.prune_processed(bridge.state.cursor("vps"))
                        processed = 0
                else:
                    time.sleep(2)
        finally:
            vps.close()
    finally:
        source.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"library bridge stopped: {type(error).__name__} "
              f"{getattr(error, 'pgcode', '') or ''}", file=sys.stderr)
        raise SystemExit(1)
