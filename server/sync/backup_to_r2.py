"""Daily full VPS database backup with an R2 round-trip integrity check."""

from datetime import datetime, timezone
import filecmp
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request


MAX_BYTES = 90 * 1024 * 1024


def backup(
    directory="/var/backups/AniAura-sync",
    run=subprocess.run,
    open_url=urllib.request.urlopen,
    endpoint=None,
    token_file=None,
):
    os.umask(0o077)
    endpoint = endpoint or os.environ["R2_BACKUP_URL"]
    token_file = token_file or os.environ.get(
        "R2_BACKUP_TOKEN_FILE", "/etc/AniAura-backup/r2-upload-token",
    )
    token = Path(token_file).read_text().strip()
    if not token:
        raise ValueError("R2 backup token is empty")
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    with tempfile.TemporaryDirectory(prefix="daily-", dir=directory) as work:
        dump = Path(work) / "database.dump"
        downloaded = Path(work) / "verified.dump"
        run(["pg_dump", "--format=custom", "--file", str(dump),
             "AniAura_sync_stage"], check=True)
        run(["pg_restore", "--list", str(dump)], check=True,
            stdout=subprocess.DEVNULL)
        size = dump.stat().st_size
        if not 0 < size <= MAX_BYTES:
            raise ValueError("database dump exceeds the 90 MiB backup limit")
        dump_bytes = dump.read_bytes()
        digest = hashlib.sha256(dump_bytes).hexdigest()
        name = f"AniAura-sync-stage-{stamp}-{digest}.dump"
        url = f"{endpoint.rstrip('/')}/{name}"
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/octet-stream",
            "Content-Length": str(size),
            "X-Backup-SHA256": digest,
            "User-Agent": "Mozilla/5.0",
        }
        request = urllib.request.Request(
            url, data=dump_bytes, headers=headers, method="PUT",
        )
        with open_url(request, timeout=600) as response:
            stored = json.loads(response.read())
        if stored != {"key": f"daily/{name}", "size": size}:
            raise ValueError("R2 did not confirm the uploaded backup")

        request = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "User-Agent": "Mozilla/5.0",
            },
            method="GET",
        )
        with open_url(request, timeout=600) as response, downloaded.open("wb") as out:
            while chunk := response.read(1024 * 1024):
                out.write(chunk)
        if not filecmp.cmp(dump, downloaded, shallow=False):
            raise ValueError("R2 backup differs from the database dump")
        run(["pg_restore", "--file=/dev/null", str(downloaded)], check=True)
    # shortcut: backups are not pruned; add retention before R2 storage grows.
    print(f"verified daily/{name}")


if __name__ == "__main__":
    backup()
