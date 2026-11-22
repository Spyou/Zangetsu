"""Seed the unpublished VPS library from one consistent Supabase snapshot."""

import json
import os

import psycopg2

from history_bridge import load_source_dsn, source_connection_kwargs
from library_bridge import TABLE_FIELDS


ORDER = (
    "list_categories", "profile_list_categories",
    "mylist", "profile_mylist",
    "mylist_categories", "profile_mylist_categories",
)


def seed(source, stage):
    with stage.cursor() as cursor:
        cursor.execute("select current_database()")
        if cursor.fetchone()[0] != "AniAura_sync_stage":
            raise ValueError("library seed is only allowed on the unpublished stage")
        for table in (*ORDER, "mylist_sync_clock", "mylist_sync_tombstones",
                      "library_bridge_events", "library_bridge_latest",
                      "library_bridge_cursors"):
            schema = "sync_private" if table.startswith("library_bridge_") else "sync_api"
            cursor.execute(f"select count(*) from {schema}.{table}")
            if cursor.fetchone()[0]:
                raise ValueError(f"{table} is not empty; refusing to replace data")

    source.set_session(isolation_level="REPEATABLE READ", readonly=True)
    with source:
        snapshots = {}
        with source.cursor() as cursor:
            for table in (*ORDER, "mylist_sync_clock", "mylist_sync_tombstones"):
                cursor.execute(f"select row_to_json(row) from public.{table} row")
                snapshots[table] = [row[0] for row in cursor.fetchall()]

        with stage:
            with stage.cursor() as cursor:
                cursor.execute("set local AniAura.bridge_replay = 'on'")
                for table in ORDER:
                    columns = ", ".join(TABLE_FIELDS[table])
                    for start in range(0, len(snapshots[table]), 500):
                        batch = snapshots[table][start:start + 500]
                        cursor.execute(
                            f"insert into sync_api.{table} ({columns}) "
                            f"select {columns} from jsonb_populate_recordset("
                            f"null::sync_api.{table}, %s::jsonb)",
                            (json.dumps(batch),),
                        )
                for start in range(0, len(snapshots["mylist_sync_tombstones"]), 500):
                    batch = snapshots["mylist_sync_tombstones"][start:start + 500]
                    cursor.execute(
                        "insert into sync_api.mylist_sync_tombstones "
                        "select * from jsonb_populate_recordset("
                        "null::sync_api.mylist_sync_tombstones, %s::jsonb)",
                        (json.dumps(batch),),
                    )
                for start in range(0, len(snapshots["mylist_sync_clock"]), 500):
                    batch = snapshots["mylist_sync_clock"][start:start + 500]
                    cursor.execute(
                        "insert into sync_api.mylist_sync_clock "
                        "select * from jsonb_populate_recordset("
                        "null::sync_api.mylist_sync_clock, %s::jsonb) where true "
                        "on conflict (user_key, profile_scope) do update "
                        "set version = greatest(sync_api.mylist_sync_clock.version, "
                        "excluded.version)",
                        (json.dumps(batch),),
                    )
                cursor.execute(
                    "insert into sync_api.mylist_sync_clock "
                    "select user_key, profile_scope, max(sync_version) "
                    "from sync_api.mylist_sync_tombstones "
                    "group by user_key, profile_scope "
                    "on conflict (user_key, profile_scope) do update "
                    "set version = greatest(sync_api.mylist_sync_clock.version, "
                    "excluded.version)"
                )
                for table in (*ORDER, "mylist_sync_tombstones"):
                    cursor.execute(f"select count(*) from sync_api.{table}")
                    if cursor.fetchone()[0] != len(snapshots[table]):
                        raise AssertionError(f"{table} snapshot count mismatch")
    return {table: len(rows) for table, rows in snapshots.items()}


def main():
    source = psycopg2.connect(
        **source_connection_kwargs(load_source_dsn(os.environ["SUPABASE_DSN_FILE"])),
        sslmode="require", connect_timeout=10,
    )
    try:
        stage = psycopg2.connect(os.environ["VPS_DSN"], connect_timeout=10)
        try:
            print(seed(source, stage))
        finally:
            stage.close()
    finally:
        source.close()


if __name__ == "__main__":
    main()
