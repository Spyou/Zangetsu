"""Temporary watch-history bridge between old Supabase and new VPS clients."""

from dataclasses import dataclass
from datetime import datetime
import json
import os
from pathlib import Path
import sys
import time
from urllib.parse import unquote, urlsplit


@dataclass(frozen=True)
class HistoryEvent:
    origin: str
    id: int
    user_key: str
    profile_id: str | None
    source_id: str
    show_id: str
    operation: str
    row_data: dict | None
    changed_at: datetime

    @property
    def key(self):
        return (self.user_key, self.profile_id or "", self.source_id, self.show_id)


class HistoryBridge:
    def __init__(self, source, vps, state):
        self.source = source
        self.vps = vps
        self.state = state

    def process_once(self):
        candidates = [
            event
            for event in (
                self.source.next_event(self.state.cursor("supabase")),
                self.vps.next_event(self.state.cursor("vps")),
            )
            if event is not None
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


class PostgresHistoryDatabase:
    """One end of the bridge; only the two fixed history table names are used."""

    def __init__(self, connection, origin):
        if origin not in ("supabase", "vps"):
            raise ValueError("unknown bridge origin")
        self.connection = connection
        self.origin = origin
        self.schema = "public" if origin == "supabase" else "sync_api"

    def next_event(self, after_id):
        with self.connection.cursor() as cursor:
            cursor.execute(
                "select id, user_key, profile_id, source_id, show_id, "
                "operation, row_data, changed_at "
                "from sync_private.history_bridge_events "
                "where id > %s order by id limit 1",
                (after_id,),
            )
            row = cursor.fetchone()
        return HistoryEvent(self.origin, *row) if row else None

    def apply(self, event):
        if event.operation not in ("upsert", "delete"):
            raise ValueError("unknown history operation")
        table = f"{self.schema}.{'profile_history' if event.profile_id else 'history'}"
        keys = "user_key,profile_id,source_id,show_id" if event.profile_id else "user_key,source_id,show_id"
        with self.connection:
            with self.connection.cursor() as cursor:
                cursor.execute("set local AniAura.bridge_replay = 'on'")
                if event.operation == "delete":
                    filters = "user_key = %s and source_id = %s and show_id = %s"
                    values = [event.user_key, event.source_id, event.show_id]
                    if event.profile_id:
                        filters += " and profile_id = %s"
                        values.append(event.profile_id)
                    cursor.execute(f"delete from {table} where {filters}", values)
                    return
                if event.row_data is None:
                    raise ValueError("upsert event has no row data")
                update_columns = (
                    "show_title", "cover", "cover_headers", "show_url", "category",
                    "episode_id", "episode_number", "episode_url", "position_ms",
                    "duration_ms", "updated_at", "mal_id",
                )
                updates = ", ".join(f"{column} = excluded.{column}" for column in update_columns)
                cursor.execute(
                    f"insert into {table} "
                    f"select * from jsonb_populate_record(null::{table}, %s::jsonb) "
                    f"where true on conflict ({keys}) do update set {updates}",
                    (json.dumps(event.row_data),),
                )

    def prune_processed(self, through_id, retain=100):
        """Remove only acknowledged journal entries, never user history rows."""
        cutoff = through_id - retain
        if cutoff <= 0:
            return 0
        with self.connection:
            with self.connection.cursor() as cursor:
                cursor.execute(
                    "delete from sync_private.history_bridge_events where id in ("
                    "select id from sync_private.history_bridge_events "
                    "where id <= %s order by id limit 1000)",
                    (cutoff,),
                )
                return cursor.rowcount


class PostgresBridgeState:
    """Winner and replay cursor live together in the VPS database."""

    def __init__(self, connection):
        self.connection = connection

    def cursor(self, origin):
        with self.connection.cursor() as cursor:
            cursor.execute(
                "select last_id from sync_private.history_bridge_cursors "
                "where origin = %s",
                (origin,),
            )
            row = cursor.fetchone()
        return row[0] if row else 0

    def latest(self, key):
        with self.connection.cursor() as cursor:
            cursor.execute(
                "select origin, event_id, user_key, nullif(profile_scope, ''), "
                "source_id, show_id, operation, row_data, changed_at "
                "from sync_private.history_bridge_latest "
                "where user_key = %s and profile_scope = %s "
                "and source_id = %s and show_id = %s",
                key,
            )
            row = cursor.fetchone()
        return HistoryEvent(*row) if row else None

    def commit(self, processed, winner):
        with self.connection:
            with self.connection.cursor() as cursor:
                cursor.execute(
                    "insert into sync_private.history_bridge_latest "
                    "(user_key, profile_scope, source_id, show_id, origin, "
                    "event_id, operation, changed_at, row_data) "
                    "values (%s,%s,%s,%s,%s,%s,%s,%s,%s::jsonb) "
                    "on conflict (user_key, profile_scope, source_id, show_id) "
                    "do update set origin = excluded.origin, "
                    "event_id = excluded.event_id, operation = excluded.operation, "
                    "changed_at = excluded.changed_at, row_data = excluded.row_data",
                    (*winner.key, winner.origin, winner.id, winner.operation,
                     winner.changed_at, json.dumps(winner.row_data)),
                )
                cursor.execute(
                    "insert into sync_private.history_bridge_cursors (origin, last_id) "
                    "values (%s, %s) on conflict (origin) do update "
                    "set last_id = greatest(sync_private.history_bridge_cursors.last_id, "
                    "excluded.last_id)",
                    (processed.origin, processed.id),
                )


def load_source_dsn(path):
    raw = Path(path).read_text()
    locations = [index for scheme in ("postgresql://", "postgres://")
                 if (index := raw.find(scheme)) >= 0]
    if not locations:
        raise ValueError("bridge source must be a PostgreSQL URL with a host")
    dsn = raw[min(locations):].split()[0]
    parsed = urlsplit(dsn)
    if parsed.scheme not in ("postgres", "postgresql") or not parsed.hostname:
        raise ValueError("bridge source must be a PostgreSQL URL with a host")
    return dsn


def source_connection_kwargs(dsn):
    parsed = urlsplit(dsn)
    if (parsed.scheme not in ("postgres", "postgresql") or not parsed.hostname
            or not parsed.username or parsed.password is None or not parsed.path):
        raise ValueError("incomplete PostgreSQL source URL")
    return {
        "host": parsed.hostname,
        "port": parsed.port or 5432,
        "user": unquote(parsed.username),
        "password": unquote(parsed.password),
        "dbname": unquote(parsed.path.lstrip("/")),
    }


def main():
    import psycopg2

    source_dsn = load_source_dsn(os.environ["SUPABASE_DSN_FILE"])
    vps_dsn = os.environ["VPS_DSN"]
    source_conn = psycopg2.connect(
        **source_connection_kwargs(source_dsn), sslmode="require", connect_timeout=10
    )
    try:
        vps_conn = psycopg2.connect(vps_dsn, connect_timeout=10)
        try:
            with vps_conn:
                with vps_conn.cursor() as cursor:
                    cursor.execute("select pg_try_advisory_lock(%s)", (238903481230915,))
                    if not cursor.fetchone()[0]:
                        return 0  # Another bridge instance owns the session lock.
            source = PostgresHistoryDatabase(source_conn, "supabase")
            vps = PostgresHistoryDatabase(vps_conn, "vps")
            state = PostgresBridgeState(vps_conn)
            bridge = HistoryBridge(source, vps, state)
            processed_since_prune = 0
            while True:
                if bridge.process_once():
                    processed_since_prune += 1
                    if processed_since_prune >= 1000:
                        source.prune_processed(state.cursor("supabase"))
                        vps.prune_processed(state.cursor("vps"))
                        processed_since_prune = 0
                else:
                    time.sleep(2)
        finally:
            vps_conn.close()
    finally:
        source_conn.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"history bridge stopped: {type(error).__name__}", file=sys.stderr)
        raise SystemExit(1)
