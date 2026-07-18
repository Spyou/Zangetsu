#!/usr/bin/env python3
"""One-time data migration: Appwrite (old backend) -> Supabase (new backend).

Exports mylist/history/backups documents + avatar files from Appwrite via
REST, transforms each doc with tools/migration/transform.py, and bulk-upserts
the rows into Supabase (service role). Re-running is safe: Supabase tables
are keyed on the same columns Appwrite dedup'd on, so upsert = no dupes.

All config comes from ENV — nothing is hardcoded, nothing is written to disk.

Usage:
    python3 export_import.py                 # full run
    python3 export_import.py --limit 5        # small dry-ish sample size
    python3 export_import.py --dry-run         # export+transform+print, no Supabase writes
    python3 export_import.py --limit 5 --dry-run

Required env vars (SUPABASE_* only required unless --dry-run):
    APPWRITE_ENDPOINT            (default: https://sgp.cloud.appwrite.io/v1)
    APPWRITE_PROJECT_ID          (default: 6a1ed44f0029b50bccde)
    APPWRITE_API_KEY             (required)
    SUPABASE_URL                 (required unless --dry-run)
    SUPABASE_SERVICE_ROLE_KEY    (required unless --dry-run)
"""
import argparse
import json
import os
import sys

from transform import mylist_row, history_row, backup_row

APPWRITE_DATABASE_ID = "main"
PAGE_SIZE = 100
UPSERT_BATCH_SIZE = 500

# collection -> (transform fn, supabase table, on_conflict columns matching the PK)
COLLECTIONS = {
    "mylist": (mylist_row, "mylist", "user_key,source_id,item_id"),
    "history": (history_row, "history", "user_key,source_id,show_id"),
    "backups": (backup_row, "backups", "user_key"),
}


def appwrite_headers(project_id, api_key):
    return {"X-Appwrite-Project": project_id, "X-Appwrite-Key": api_key}


def fetch_appwrite_documents(endpoint, project_id, api_key, collection_id, limit=None):
    """Paginate GET /databases/{db}/collections/{id}/documents, 100/page.

    ponytail: only the documents REST path is used (works on Appwrite 1.9.x).
    The brief mentions a possible /tablesdb/.../rows path on some 1.9.x
    installs, but the documents endpoint is still served there too, so no
    fallback branch is needed — one request path, one thing to maintain.
    """
    import requests

    docs = []
    offset = 0
    url = f"{endpoint}/databases/{APPWRITE_DATABASE_ID}/collections/{collection_id}/documents"
    while True:
        page_limit = PAGE_SIZE
        if limit is not None:
            remaining = limit - len(docs)
            if remaining <= 0:
                break
            page_limit = min(PAGE_SIZE, remaining)

        # Appwrite 1.9.x REST wants queries as URL-encoded JSON strings
        # ({"method":"limit","values":[n]}), NOT the legacy "limit(n)" form.
        resp = requests.get(
            url,
            headers=appwrite_headers(project_id, api_key),
            params=[
                ("queries[]", json.dumps({"method": "limit", "values": [page_limit]})),
                ("queries[]", json.dumps({"method": "offset", "values": [offset]})),
            ],
            timeout=30,
        )
        resp.raise_for_status()
        body = resp.json()
        page = body.get("documents", [])
        docs.extend(page)
        offset += len(page)
        if len(page) < page_limit or not page:
            break
        if limit is not None and len(docs) >= limit:
            break

    return docs[:limit] if limit is not None else docs


def transform_documents(docs, transform_fn):
    """Run transform_fn over docs; skip (don't raise on) malformed ones.

    transform.py's row functions do doc["key"] lookups that raise KeyError
    on a missing field. One bad document must not abort the whole export,
    so each doc gets its own try/except and skips are counted separately.
    """
    rows = []
    skipped = 0
    for doc in docs:
        try:
            rows.append(transform_fn(doc))
        except (KeyError, TypeError, ValueError):
            skipped += 1
    return rows, skipped


def upsert_batches(supabase_client, table, rows, on_conflict, batch_size=UPSERT_BATCH_SIZE):
    """Upsert rows into a Supabase table in batches. Returns rows loaded."""
    loaded = 0
    for i in range(0, len(rows), batch_size):
        batch = rows[i : i + batch_size]
        supabase_client.table(table).upsert(batch, on_conflict=on_conflict).execute()
        loaded += len(batch)
    return loaded


def migrate_avatars(endpoint, project_id, api_key, supabase_client, dry_run, limit=None):
    """For each Appwrite USER with a prefs.avatarId, download that avatar file
    and upload it to the Supabase avatars bucket at legacy/<userId>.jpg — the
    exact path the migrate-account function's claimData points profiles at.

    The app stores avatars under a RANDOM file id (ID.unique()) and links the
    owner via account prefs['avatarId'] — the file is NOT named after the user.
    So we must iterate users and resolve user -> avatarId; guessing the owner
    from the filename produces junk that no profile ever resolves to.
    Never aborts the run.
    """
    import requests

    hdr = appwrite_headers(project_id, api_key)
    uploaded = 0
    skipped = 0
    offset = 0
    while True:
        q = [
            ("queries[]", json.dumps({"method": "limit", "values": [PAGE_SIZE]})),
            ("queries[]", json.dumps({"method": "offset", "values": [offset]})),
        ]
        try:
            page = requests.get(f"{endpoint}/users", headers=hdr, params=q, timeout=30).json()
        except Exception as exc:  # noqa: BLE001 - listing must never abort the run
            print(f"  [avatars] could not list users: {exc}")
            break
        users = page.get("users", [])
        total = page.get("total", 0)
        if not users:
            break

        for u in users:
            uid = u.get("$id")
            avatar_id = (u.get("prefs") or {}).get("avatarId")
            if not avatar_id:
                continue
            if limit is not None and uploaded >= limit:
                return uploaded, skipped
            if dry_run:
                uploaded += 1  # "would upload"
                continue
            try:
                dl = requests.get(
                    f"{endpoint}/storage/buckets/avatars/files/{avatar_id}/view",
                    headers=hdr, timeout=60,
                )
                if dl.status_code != 200:
                    skipped += 1
                    continue
                ct = dl.headers.get("content-type", "image/jpeg")
                supabase_client.storage.from_("avatars").upload(
                    f"legacy/{uid}.jpg", dl.content, {"content-type": ct, "upsert": "true"}
                )
                uploaded += 1
            except Exception as exc:  # noqa: BLE001 - one bad avatar must not abort the run
                print(f"  [avatars] skip user {uid}: {exc}")
                skipped += 1

        offset += len(users)
        if offset >= total:
            break

    return uploaded, skipped


def run(args):
    endpoint = os.environ.get("APPWRITE_ENDPOINT", "https://sgp.cloud.appwrite.io/v1")
    project_id = os.environ.get("APPWRITE_PROJECT_ID", "6a1ed44f0029b50bccde")
    api_key = os.environ.get("APPWRITE_API_KEY")
    supabase_url = os.environ.get("SUPABASE_URL")
    supabase_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")

    if not api_key:
        sys.exit("APPWRITE_API_KEY is required")
    if not args.dry_run and not (supabase_url and supabase_key):
        sys.exit("SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required (unless --dry-run)")

    supabase_client = None
    if not args.dry_run:
        from supabase import create_client

        supabase_client = create_client(supabase_url, supabase_key)

    summary = {}

    for collection_id, (transform_fn, table, on_conflict) in COLLECTIONS.items():
        print(f"[{collection_id}] exporting...")
        docs = fetch_appwrite_documents(endpoint, project_id, api_key, collection_id, args.limit)
        rows, skipped = transform_documents(docs, transform_fn)

        loaded = 0
        if not args.dry_run and rows:
            loaded = upsert_batches(supabase_client, table, rows, on_conflict)

        summary[collection_id] = {
            "exported": len(docs),
            "transformed": len(rows),
            "skipped": skipped,
            "loaded": loaded if not args.dry_run else 0,
        }
        action = "would load" if args.dry_run else "loaded"
        print(
            f"[{collection_id}] exported={len(docs)} transformed={len(rows)} "
            f"skipped={skipped} {action}={len(rows) if args.dry_run else loaded}"
        )

    print("[avatars] migrating...")
    avatars_uploaded, avatars_skipped = migrate_avatars(
        endpoint, project_id, api_key, supabase_client, args.dry_run, args.limit
    )
    verb = "would upload" if args.dry_run else "uploaded"
    print(f"[avatars] {verb}={avatars_uploaded} skipped={avatars_skipped}")

    print("\n=== Summary ===")
    for collection_id, counts in summary.items():
        print(
            f"{collection_id}: exported={counts['exported']} transformed={counts['transformed']} "
            f"skipped={counts['skipped']} loaded={counts['loaded']}"
        )
    print(f"avatars: uploaded={avatars_uploaded} skipped={avatars_skipped}")
    if args.dry_run:
        print("(dry-run: no writes were made to Supabase)")


def build_arg_parser():
    parser = argparse.ArgumentParser(description="Migrate user data from Appwrite to Supabase.")
    parser.add_argument("--limit", type=int, default=None, help="cap docs/files per collection (small dry run)")
    parser.add_argument("--dry-run", action="store_true", help="export+transform+print counts, skip Supabase writes")
    return parser


if __name__ == "__main__":
    run(build_arg_parser().parse_args())
