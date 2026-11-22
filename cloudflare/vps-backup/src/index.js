const MAX_BYTES = 90 * 1024 * 1024;
const FILE_NAME =
  /^AniAura-sync-stage-\d{4}-\d{2}-\d{2}T\d{6}Z-([a-f0-9]{64})\.dump$/;

function response(status, message) {
  return new Response(message, { status });
}

function secretMatches(received, expected) {
  let difference = received.length ^ expected.length;
  const length = Math.max(received.length, expected.length);
  for (let index = 0; index < length; index++) {
    difference |= (received.charCodeAt(index) || 0) ^
      (expected.charCodeAt(index) || 0);
  }
  return difference === 0;
}

function authorized(request, token) {
  if (!token) return false;
  const authorization = request.headers.get("Authorization") || "";
  return secretMatches(authorization, `Bearer ${token}`);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/v1\/backup\/([^/]+)$/);
    const file = match?.[1].match(FILE_NAME);
    if (!file) return response(404, "Not found");
    if (!authorized(request, env.BACKUP_TOKEN)) return response(401, "Unauthorized");

    const key = `daily/${match[1]}`;
    if (request.method === "PUT") {
      const size = Number(request.headers.get("Content-Length"));
      if (!Number.isSafeInteger(size) || size < 1 || size > MAX_BYTES ||
          request.headers.get("X-Backup-SHA256") !== file[1]) {
        return response(413, "Invalid backup size");
      }
      if (await env.BACKUPS.head(key)) return response(409, "Backup already exists");
      const object = await env.BACKUPS.put(key, request.body, {
        httpMetadata: { contentType: "application/octet-stream" },
      });
      if (object.size !== size) return response(502, "Stored size mismatch");
      return Response.json({ key, size: object.size }, { status: 201 });
    }

    if (request.method === "GET") {
      const object = await env.BACKUPS.get(key);
      if (!object) return response(404, "Backup not found");
      return new Response(object.body, {
        headers: {
          "Content-Length": String(object.size),
          "Content-Type": "application/octet-stream",
        },
      });
    }

    return new Response("Method not allowed", {
      status: 405,
      headers: { Allow: "GET, PUT" },
    });
  },
};
