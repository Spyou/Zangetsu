"""Compare user-visible library rows without printing identifiers or titles."""

import os
import subprocess

import psycopg2

from history_bridge import load_source_dsn, source_connection_kwargs
from library_bridge import TABLE_KEYS

CHECK_KEYS = {
    **TABLE_KEYS,
    "mylist_sync_tombstones": (
        "user_key", "profile_scope", "source_id", "item_id",
    ),
}


def compare(source, ssh_key, host, table):
    keys = CHECK_KEYS.get(table)
    if keys is None:
        raise ValueError("unsupported library table")
    identity = ", ".join(keys)
    contents = "to_jsonb(row)"
    if table in ("mylist", "profile_mylist"):
        contents += " - 'sync_id' - 'sync_version'"
    elif table == "mylist_sync_tombstones":
        contents += " - 'sync_version'"
    query = (
        f"select md5(concat_ws(chr(31), {identity})), "
        f"md5(({contents})::text) from {{schema}}.{table} row order by 1"
    )
    with source.cursor() as cursor:
        cursor.execute(query.format(schema="public"))
        source_rows = dict(cursor.fetchall())
    stage_query = query.format(schema="sync_api")
    result = subprocess.run(
        ["ssh", "-i", ssh_key, "-o", "BatchMode=yes", host,
         "sudo -u AniAura_bridge psql -d AniAura_sync_stage -At -F ' ' -c "
         + '"' + stage_query + '"'],
        capture_output=True, text=True, check=True,
    )
    stage_rows = dict(line.split(" ", 1) for line in result.stdout.splitlines())
    return {
        "source": len(source_rows), "stage": len(stage_rows),
        "source_only": len(source_rows.keys() - stage_rows.keys()),
        "stage_only": len(stage_rows.keys() - source_rows.keys()),
        "different": sum(
            source_rows[key] != stage_rows[key]
            for key in source_rows.keys() & stage_rows.keys()
        ),
    }


def main():
    source = psycopg2.connect(
        **source_connection_kwargs(load_source_dsn(os.environ["SUPABASE_DSN_FILE"])),
        sslmode="require", connect_timeout=10,
    )
    try:
        for table in CHECK_KEYS:
            result = compare(
                source, os.environ["ZANGETSU_SSH_KEY"],
                os.environ["ZANGETSU_VPS_HOST"], table,
            )
            print(table, result)
            if (result["source_only"] or result["stage_only"]
                    or result["different"]):
                raise SystemExit(1)
    finally:
        source.close()


if __name__ == "__main__":
    main()
