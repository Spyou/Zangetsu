"""One-account HTTPS + bridge smoke test; read app session XML from stdin."""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import xml.etree.ElementTree as ET

import psycopg2

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../server/sync"))
from history_bridge import load_source_dsn, source_connection_kwargs


BASE = "https://sync.AniAura.online/history"
SOURCE = "vps-bridge-pilot"


def request(token, method, user_key, show_id, payload=None):
    query = urllib.parse.urlencode({
        "user_key": f"eq.{user_key}", "source_id": f"eq.{SOURCE}",
        "show_id": f"eq.{show_id}", "select": "show_id",
    })
    body = None if payload is None else json.dumps(payload).encode()
    headers = {"Authorization": f"Bearer {token}"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    with urllib.request.urlopen(
        urllib.request.Request(
            BASE + ("?" + query if method != "POST" else ""),
            data=body, method=method, headers=headers,
        ), timeout=10,
    ) as response:
        return json.load(response) if method == "GET" else response.status


def source_has(connection, user_key, show_id):
    with connection.cursor() as cursor:
        cursor.execute(
            "select exists(select 1 from public.history where user_key = %s "
            "and source_id = %s and show_id = %s)",
            (user_key, SOURCE, show_id),
        )
        return cursor.fetchone()[0]


def wait_for(predicate, expected):
    for _ in range(30):
        if predicate() == expected:
            return
        time.sleep(1)
    raise AssertionError("bridge did not converge within 30 seconds")


def main():
    xml = ET.fromstring(sys.stdin.read())
    session = json.loads(next(
        element.text for element in xml
        if "auth-token" in element.attrib.get("name", "")
    ))
    user_key, token = session["user"]["id"], session["access_token"]
    connection = psycopg2.connect(
        **source_connection_kwargs(load_source_dsn(os.environ["SUPABASE_DSN_FILE"])),
        sslmode="require", connect_timeout=10,
    )
    show_ids = [str(uuid.uuid4()), str(uuid.uuid4())]
    try:
        first, second = show_ids
        request(token, "POST", user_key, first, {
            "user_key": user_key, "source_id": SOURCE, "show_id": first,
            "show_title": "VPS bridge test", "updated_at": int(time.time() * 1000),
        })
        wait_for(lambda: source_has(connection, user_key, first), True)
        request(token, "DELETE", user_key, first)
        wait_for(lambda: source_has(connection, user_key, first), False)
        with connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "insert into public.history "
                    "(user_key, source_id, show_id, show_title, updated_at) "
                    "values (%s, %s, %s, %s, %s)",
                    (user_key, SOURCE, second, "Supabase bridge test", int(time.time() * 1000)),
                )
        wait_for(lambda: bool(request(token, "GET", user_key, second)), True)
        with connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "delete from public.history where user_key = %s "
                    "and source_id = %s and show_id = %s",
                    (user_key, SOURCE, second),
                )
        wait_for(lambda: bool(request(token, "GET", user_key, second)), False)
        print("pilot-pass: authenticated reads, both write directions, both deletes")
    finally:
        for show_id in show_ids:
            try:
                request(token, "DELETE", user_key, show_id)
            except (urllib.error.URLError, TimeoutError):
                pass
        with connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "delete from public.history where user_key = %s "
                    "and source_id = %s and show_id = any(%s)",
                    (user_key, SOURCE, show_ids),
                )
        connection.close()


if __name__ == "__main__":
    main()
