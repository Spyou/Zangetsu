import assert from "node:assert/strict";
import { test } from "node:test";
import worker from "./src/index.js";

const token = "test-token";
const filename = `AniAura-sync-stage-2026-10-19T031500Z-${"a".repeat(64)}.dump`;

function storage() {
  const objects = new Map();
  return {
    objects,
    binding: {
      async head(key) {
        const bytes = objects.get(key);
        return bytes ? { size: bytes.byteLength } : null;
      },
      async put(key, body) {
        const bytes = await new Response(body).arrayBuffer();
        objects.set(key, bytes);
        return { size: bytes.byteLength };
      },
      async get(key) {
        const bytes = objects.get(key);
        return bytes ? { body: new Response(bytes).body, size: bytes.byteLength } : null;
      },
    },
  };
}

function putRequest(url, headers, body) {
  return {
    method: "PUT",
    url,
    headers: new Headers(headers),
    body: new Blob([body]).stream(),
  };
}

test("accepts an authenticated upload and returns the stored bytes", async () => {
  const r2 = storage();
  const bytes = new TextEncoder().encode("backup");
  const headers = {
    Authorization: `Bearer ${token}`,
    "Content-Length": String(bytes.byteLength),
    "X-Backup-SHA256": "a".repeat(64),
  };
  const put = await worker.fetch(
    putRequest(`https://backup.test/v1/backup/${filename}`, headers, bytes),
    { BACKUP_TOKEN: token, BACKUPS: r2.binding },
  );
  assert.equal(put.status, 201);
  assert.equal((await put.json()).size, bytes.byteLength);

  const get = await worker.fetch(
    new Request(`https://backup.test/v1/backup/${filename}`, {
      headers: { Authorization: `Bearer ${token}` },
    }),
    { BACKUP_TOKEN: token, BACKUPS: r2.binding },
  );
  assert.deepEqual(new Uint8Array(await get.arrayBuffer()), bytes);
});

test("rejects unauthenticated and malformed uploads", async () => {
  const r2 = storage();
  const url = `https://backup.test/v1/backup/${filename}`;
  const denied = await worker.fetch(new Request(url), {
    BACKUP_TOKEN: token, BACKUPS: r2.binding,
  });
  assert.equal(denied.status, 401);

  const malformed = await worker.fetch(putRequest(url, {
      Authorization: `Bearer ${token}`,
      "Content-Length": "6",
      "X-Backup-SHA256": "b".repeat(64),
    }, "backup"), { BACKUP_TOKEN: token, BACKUPS: r2.binding });
  assert.equal(malformed.status, 413);
  assert.equal(r2.objects.size, 0);
});
