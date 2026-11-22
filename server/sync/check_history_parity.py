"""Compare source and VPS watch-history rows without printing user identifiers."""

import os
import subprocess

import psycopg2

from history_bridge import load_source_dsn, source_connection_kwargs


def row_hashes(table):
    if table not in ("history", "profile_history"):
        raise ValueError("unsupported table")
    parts = "user_key, source_id, show_id"
    if table == "profile_history":
        parts += ", profile_id"
    return (
        f"select md5(concat_ws(chr(31), {parts})), "
        f"md5(to_jsonb(row)::text) from {{schema}}.{table} row "
        f"order by 1"
    )


def compare(source, ssh_key, host, table):
    query = row_hashes(table)
    with source.cursor() as cursor:
        cursor.execute(query.format(schema="public"))
        source_rows = dict(cursor.fetchall())
    result = subprocess.run(
        ["ssh", "-i", ssh_key, "-o", "BatchMode=yes", host,
         "sudo -u AniAura_bridge psql -d AniAura_sync_stage -At -F ' ' -c "
         + "'" + query.format(schema="sync_api") + "'"],
        capture_output=True,
        text=True,
        check=True,
    )
    stage_rows = dict(line.split(" ", 1) for line in result.stdout.splitlines())
    return {
        "source": len(source_rows),
        "stage": len(stage_rows),
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
        sslmode="require",
        connect_timeout=10,
    )
    try:
        for table in ("history", "profile_history"):
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
