"""Replace an unpublished VPS stage snapshot from Supabase, then replay journals."""

import json
import os

import psycopg2

from history_bridge import load_source_dsn, source_connection_kwargs


def refresh(source, stage):
    with stage.cursor() as cursor:
        cursor.execute("select current_database()")
        database = cursor.fetchone()[0]
    if database != "AniAura_sync_stage":
        raise ValueError("snapshot refresh is only allowed on the unpublished stage")

    source.set_session(isolation_level="REPEATABLE READ", readonly=True)
    with source:
        snapshots = {}
        with source.cursor() as cursor:
            for table in ("history", "profile_history"):
                cursor.execute(f"select row_to_json(row) from public.{table} row")
                snapshots[table] = [row[0] for row in cursor.fetchall()]

        with stage:
            with stage.cursor() as cursor:
                cursor.execute("set local AniAura.bridge_replay = 'on'")
                for table in ("history", "profile_history"):
                    cursor.execute(f"delete from sync_api.{table}")
                    for start in range(0, len(snapshots[table]), 500):
                        batch = snapshots[table][start:start + 500]
                        cursor.execute(
                            f"insert into sync_api.{table} "
                            f"select * from jsonb_populate_recordset("
                            f"null::sync_api.{table}, %s::jsonb)",
                            (json.dumps(batch),),
                        )
                cursor.execute("delete from sync_private.history_bridge_latest")
                cursor.execute("delete from sync_private.history_bridge_cursors")
                cursor.execute("delete from sync_private.history_bridge_events")
                for table, rows in snapshots.items():
                    cursor.execute(f"select count(*) from sync_api.{table}")
                    if cursor.fetchone()[0] != len(rows):
                        raise AssertionError(f"{table} snapshot count mismatch")
    return {table: len(rows) for table, rows in snapshots.items()}


def main():
    source = psycopg2.connect(
        **source_connection_kwargs(load_source_dsn(os.environ["SUPABASE_DSN_FILE"])),
        sslmode="require",
        connect_timeout=10,
    )
    try:
        stage = psycopg2.connect(os.environ["VPS_DSN"], connect_timeout=10)
        try:
            print(refresh(source, stage))
        finally:
            stage.close()
    finally:
        source.close()


if __name__ == "__main__":
    main()
