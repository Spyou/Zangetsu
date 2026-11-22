"""Copy existing personal content into the unpublished VPS stage once."""

import json
import os

import psycopg2

from content_bridge import TABLE_FIELDS
from history_bridge import load_source_dsn, source_connection_kwargs


ORDER = (
    "viewer_profiles", "reading_history", "profile_reading_history", "backups",
)


def seed(source, stage):
    with stage.cursor() as cursor:
        cursor.execute("select current_database()")
        if cursor.fetchone()[0] not in (
            "AniAura_sync_stage", "AniAura_content_seed_vps_test",
        ):
            raise ValueError("content seed is only allowed on the unpublished stage")
        for table in ORDER:
            cursor.execute(f"select count(*) from sync_api.{table}")
            if cursor.fetchone()[0]:
                raise ValueError(f"{table} is not empty; refusing to replace data")
        for table in ("content_bridge_events", "content_bridge_latest",
                      "content_bridge_cursors"):
            cursor.execute(f"select count(*) from sync_private.{table}")
            if cursor.fetchone()[0]:
                raise ValueError(f"{table} is not empty; refusing to replace data")

    # A SHARE lock waits for in-flight writes and blocks new ones only while
    # the snapshot is read. The journal watermark then cannot skip a late
    # commit whose sequence ID was allocated before the snapshot.
    source.set_session(isolation_level="READ COMMITTED")
    with source:
        with source.cursor() as cursor:
            cursor.execute("lock table " + ", ".join(
                f"public.{table}" for table in ORDER
            ) + " in share mode")
            cursor.execute("select coalesce(max(id), 0) "
                           "from sync_private.content_bridge_events")
            watermark = cursor.fetchone()[0]
            snapshots = {}
            for table in ORDER:
                cursor.execute(f"select row_to_json(row) from public.{table} row")
                snapshots[table] = [row[0] for row in cursor.fetchall()]

    with stage:
        with stage.cursor() as cursor:
            cursor.execute("set local AniAura.bridge_replay = 'on'")
            for table in ORDER:
                columns = ", ".join(TABLE_FIELDS[table])
                for start in range(0, len(snapshots[table]), 500):
                    cursor.execute(
                        f"insert into sync_api.{table} ({columns}) "
                        f"select {columns} from jsonb_populate_recordset("
                        f"null::sync_api.{table}, %s::jsonb)",
                        (json.dumps(snapshots[table][start:start + 500]),),
                    )
                cursor.execute(f"select count(*) from sync_api.{table}")
                if cursor.fetchone()[0] != len(snapshots[table]):
                    raise AssertionError(f"{table} snapshot count mismatch")
            cursor.execute(
                "insert into sync_private.content_bridge_cursors "
                "(origin, last_id) values ('supabase', %s)", (watermark,),
            )
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
