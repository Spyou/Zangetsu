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

        resp = requests.get(
            url,
            headers=appwrite_headers(project_id, api_key),
            params={"queries[0]": f"limit({page_limit})", "queries[1]": f"offset({offset})"},
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


def resolve_avatar_owner(file_obj):
    """Best-effort owner id for an avatars-bucket file.

    Appwrite Storage files carry a name and a $permissions list. This repo's
    avatar uploads name the file after the owning user id (see app upload
    code), so the name (sans extension) is the primary signal; a
    user:<id> read permission is the fallback. Returns None if neither
    yields anything usable.
    """
    name = file_obj.get("name", "")
    stem = name.rsplit(".", 1)[0] if "." in name else name
    if stem:
        return stem

    for perm in file_obj.get("$permissions", []):
        # Appwrite permission strings look like: read("user:507f...")
        if perm.startswith("read(\"user:") and perm.endswith("\")"):
            return perm[len('read("user:'):-2]

    return None


def migrate_avatars(endpoint, project_id, api_key, supabase_client, dry_run, limit=None):
    """List Storage avatars bucket, download each file, upload to Supabase
    Storage avatars bucket at legacy/<ownerId>.<ext>. Never aborts the run.
    """
    import requests

    uploaded = 0
    skipped = 0
    try:
        resp = requests.get(
            f"{endpoint}/storage/buckets/avatars/files",
            headers=appwrite_headers(project_id, api_key),
            params={"queries[0]": f"limit({limit or PAGE_SIZE})"},
            timeout=30,
        )
        resp.raise_for_status()
        files = resp.json().get("files", [])
    except Exception as exc:  # noqa: BLE001 - avatar listing must never abort the run
        print(f"  [avatars] could not list bucket: {exc}")
        return 0, 0

    if limit is not None:
        files = files[:limit]

    for f in files:
        file_id = f.get("$id")
        owner = resolve_avatar_owner(f)
        if not owner:
            skipped += 1
            continue

        ext = f.get("name", "").rsplit(".", 1)[-1] if "." in f.get("name", "") else "jpg"
        dest_path = f"legacy/{owner}.{ext}"

        if dry_run:
            uploaded += 1  # "would upload"
            continue

        try:
            dl = requests.get(
                f"{endpoint}/storage/buckets/avatars/files/{file_id}/view",
                headers=appwrite_headers(project_id, api_key),
                timeout=60,
            )
            dl.raise_for_status()
            supabase_client.storage.from_("avatars").upload(
                dest_path, dl.content, {"upsert": "true"}
            )
            uploaded += 1
        except Exception as exc:  # noqa: BLE001 - one bad avatar must not abort the run
            print(f"  [avatars] skip {file_id} ({owner}): {exc}")
            skipped += 1

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
