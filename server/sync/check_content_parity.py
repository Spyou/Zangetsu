"""Compare the four content tables without printing private row data."""

import os
import subprocess

import psycopg2

from content_bridge import TABLE_KEYS
from history_bridge import load_source_dsn, source_connection_kwargs


def _fingerprints(connection, schema, table):
    keys = ", ".join(TABLE_KEYS[table])
    with connection.cursor() as cursor:
        cursor.execute(
            f"select md5(concat_ws(chr(31), {keys})), "
            f"md5(to_jsonb(row)::text) from {schema}.{table} row"
        )
        return dict(cursor.fetchall())


def compare(source, ssh_key, host, table):
    if table not in TABLE_KEYS:
        raise ValueError("unsupported content table")
    source_rows = _fingerprints(source, "public", table)
    keys = ", ".join(TABLE_KEYS[table])
    stage_query = (
        f"select md5(concat_ws(chr(31), {keys})), "
        f"md5(to_jsonb(row)::text) from sync_api.{table} row"
    )
    result = subprocess.run(
        ["ssh", "-i", ssh_key, "-o", "BatchMode=yes", host,
         "sudo -u AniAura_bridge psql -d AniAura_sync_stage -At -F ' ' -c "
         + '"' + stage_query + '"'],
        capture_output=True, text=True, check=True,
    )
    stage_rows = dict(line.split(" ", 1) for line in result.stdout.splitlines())
    shared = source_rows.keys() & stage_rows.keys()
    return {
        "source": len(source_rows),
        "stage": len(stage_rows),
        "source_only": len(source_rows.keys() - stage_rows.keys()),
        "stage_only": len(stage_rows.keys() - source_rows.keys()),
        "different": sum(source_rows[key] != stage_rows[key] for key in shared),
    }


def main():
    source = psycopg2.connect(
        **source_connection_kwargs(load_source_dsn(os.environ["SUPABASE_DSN_FILE"])),
        sslmode="require", connect_timeout=10,
    )
    try:
        for table in TABLE_KEYS:
            result = compare(
                source, os.environ["ZANGETSU_SSH_KEY"],
                os.environ["ZANGETSU_VPS_HOST"], table,
            )
            print(table, result)
            if any(result[key] for key in
                   ("source_only", "stage_only", "different")):
                raise SystemExit(1)
    finally:
        source.close()


if __name__ == "__main__":
    main()
