/**
 * Zangetsu log intake.
 *
 * The app posts a gzipped diagnostic log here when someone taps "Send report".
 * The Worker attaches it to a Discord message — so the report can be read by
 * clicking it — and keeps a copy in KV for 30 days in case Discord is down.
 *
 * Why a Worker rather than posting to Discord from the app: the APK is public
 * and the source is GPL, so anything embedded in it can be pulled straight
 * back out. The app only ever knows this URL; the webhook stays here.
 *
 * It also means a user on a network that blocks Discord is unaffected — their
 * app talks to Cloudflare, and Discord is called from here.
 *
 * Bindings (see wrangler.toml):
 *   LOGS            KV namespace
 *   AVATARS         R2 bucket for profile photos
 *   DISCORD_WEBHOOK secret — `wrangler secret put DISCORD_WEBHOOK`
 *   SUPABASE_JWT_SECRET secret — `wrangler secret put SUPABASE_JWT_SECRET`
 */

/** Refuse anything bigger. A full log is ~25KB gzipped; this is for a
 *  malformed client or someone poking at the endpoint. Also comfortably under
 *  Discord's attachment limit. */
const MAX_BYTES = 1_000_000;

/** Bumped by hand when the Worker changes, so `/health` can prove which code
 *  is actually serving. Cloudflare takes a while to roll a new version out and
 *  there is otherwise no way to tell from outside. */
const BUILD = 'ctx-3';

/** Supabase JWKS endpoint (ES256, P-256). Cached in a module global;
 *  refetched only when the token's `kid` misses the cache. */
const JWKS_URL =
  'https://eogwzrlfoercfwcfwlmv.supabase.co/auth/v1/.well-known/jwks.json';
const JWT_ISSUER = `${new URL(JWKS_URL).origin}/auth/v1`;
const AVATAR_MAX_BYTES = 256 * 1024;
let CACHED_JWKS = null;

/** Long enough to still have the log when someone gets round to mentioning it,
 *  short enough that nothing accumulates. KV expires these itself. */
const KEEP_SECONDS = 60 * 60 * 24 * 30;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-App-Version, X-Device, Authorization',
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS });
    }
    if (url.pathname === '/health') {
      // Reports whether the webhook is USABLE, never what it is. Without this
      // the only way to tell a configured Worker from an unconfigured one was
      // to send a report and read the tail, and the tail is not dependable.
      const hook = (env.DISCORD_WEBHOOK || '').trim();
      return json({
        ok: true,
        discord: hook.startsWith('https://discord.com/api/webhooks/')
          ? 'configured'
          : 'missing',
        build: BUILD,
      });
    }
    if (url.pathname === '/v1/avatar-slot' && request.method === 'POST') {
      const declaredLength = request.headers.get('content-length');
      if (declaredLength !== null) {
        const parsedLength = Number(declaredLength);
        if (!Number.isSafeInteger(parsedLength) || parsedLength < 0) {
          return json({ error: 'bad image size' }, 400);
        }
        if (parsedLength > AVATAR_MAX_BYTES) {
          return json({ error: 'image too large' }, 413);
        }
      }
      const user = await verifyAppUser(request, env);
      if (!user) return json({ error: 'unauthorized' }, 401);
      const type = (request.headers.get('content-type') || '')
        .split(';')[0]
        .trim()
        .toLowerCase();
      if (type !== 'image/jpeg' && type !== 'image/png' && type !== 'image/webp') {
        return json({ error: 'bad type' }, 400);
      }
      const body = await readBodyUpTo(request, AVATAR_MAX_BYTES);
      if (body === null) return json({ error: 'image too large' }, 413);
      if (!body.byteLength || !matchesImageSignature(type, body)) {
        return json({ error: 'bad image' }, 400);
      }
      const key = `avatars/${user}/${crypto.randomUUID()}.jpg`;
      await env.AVATARS.put(key, body, { httpMetadata: { contentType: type } });
      return json({ url: `${env.AVATAR_PUBLIC_BASE}/${key}` });
    }
    if (url.pathname !== '/v1/logs' || request.method !== 'POST') {
      return json({ error: 'not found' }, 404);
    }

    const declared = Number(request.headers.get('content-length') || 0);
    if (declared > MAX_BYTES) return json({ error: 'too large' }, 413);

    const body = await request.arrayBuffer();
    if (body.byteLength === 0) return json({ error: 'empty' }, 400);
    if (body.byteLength > MAX_BYTES) return json({ error: 'too large' }, 413);

    // Generated HERE, not by the client, so two reports can't collide and
    // nobody can choose a key that overwrites someone else's report.
    const ref = reference();
    const at = new Date().toISOString();
    const key = `${at.slice(0, 10)}/${ref}`;

    // Attacker-controlled — trim so a long string can't bloat the message or
    // the stored metadata. The note rides in the query string rather than a
    // header because people write it in their own language, and headers are
    // ASCII.
    const version = clean(request.headers.get('X-App-Version'), 32);
    const device = clean(request.headers.get('X-Device'), 64);
    const form = clean(request.headers.get('X-Form'), 8);
    const sources = clean(request.headers.get('X-Sources'), 64);
    const mode = clean(request.headers.get('X-Mode'), 32);
    const note = (url.searchParams.get('note') || '').slice(0, 200);
    // Free, and the app doesn't have to ask for a location permission to get
    // it — explains region-locked sources and blocked hosts straight away.
    const country = clean(request.cf && request.cf.country, 4);

    // Stored first: the backup copy must exist even if Discord is unreachable.
    await env.LOGS.put(key, body, {
      expirationTtl: KEEP_SECONDS,
      metadata: { ref, version, device, form, sources, mode, country, note, at },
    });

    // Best effort. The report is already safe, so a Discord outage must not
    // fail the upload and tell the user it didn't work.
    try {
      await notify(env, {
        ref, version, device, form, sources, mode, country, note, key, body,
      });
    } catch (e) {
      // Kept in KV regardless — but say so, or a broken webhook looks exactly
      // like a working one from out here.
      console.warn(`notify threw for ${ref}: ${e}`);
    }

    return json({ ref });
  },
};

/** The last few error lines in the log, for the message body.
 *
 *  Best effort in every direction: a log that won't decompress, isn't text, or
 *  has no errors in it just yields nothing and the report goes without. It must
 *  never be the reason a notification fails.
 */
async function lastErrors(body, max = 6) {
  try {
    const stream = new Response(body).body.pipeThrough(
      new DecompressionStream('gzip'),
    );
    const text = await new Response(stream).text();
    const hits = text
      .split('\n')
      // The logger's format is `HH:MM:SS.mmm E message`.
      .filter((l) => /^\d\d:\d\d:\d\d\.\d+ E /.test(l))
      .slice(-max)
      // Discord's content limit is 2000 characters and the rest of the message
      // needs room too.
      .map((l) => l.slice(0, 160));
    return hits.join('\n').slice(0, 1200);
  } catch (_) {
    return '';
  }
}

/** Six characters, no vowels — no accidental words, and easy to read out over
 *  a chat message. */
function reference() {
  const alphabet = '23456789BCDFGHJKLMNPQRSTVWXYZ';
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  return [...bytes].map((b) => alphabet[b % alphabet.length]).join('');
}

function clean(value, max) {
  if (!value) return '';
  return value.replace(/[^\x20-\x7E]/g, '').slice(0, max);
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS },
  });
}

async function getJwk(kid) {
  const hit =
    CACHED_JWKS &&
    Array.isArray(CACHED_JWKS.keys) &&
    CACHED_JWKS.keys.find((k) => k.kid === kid);
  if (hit) return hit;
  const res = await fetch(JWKS_URL);
  if (!res.ok) return null;
  CACHED_JWKS = await res.json();
  const keys = (CACHED_JWKS && CACHED_JWKS.keys) || [];
  return keys.find((k) => k.kid === kid) || null;
}

async function readBodyUpTo(request, maxBytes) {
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();

  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) {
        try {
          await reader.cancel();
        } catch (_) {}
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

function matchesImageSignature(type, bytes) {
  if (type === 'image/jpeg') {
    return (
      bytes.length >= 3 &&
      bytes[0] === 0xff &&
      bytes[1] === 0xd8 &&
      bytes[2] === 0xff
    );
  }
  if (type === 'image/png') {
    return [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every(
      (value, index) => bytes[index] === value,
    );
  }
  if (type === 'image/webp') {
    return (
      bytes.length >= 12 &&
      String.fromCharCode(...bytes.subarray(0, 4)) === 'RIFF' &&
      String.fromCharCode(...bytes.subarray(8, 12)) === 'WEBP'
    );
  }
  return false;
}

function b64urlToBytes(seg) {
  const b64 = seg.replace(/-/g, '+').replace(/_/g, '/');
  const padded = b64 + '='.repeat((4 - (b64.length % 4)) % 4);
  return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
}

function b64urlToJson(seg) {
  const bytes = b64urlToBytes(seg);
  let text = '';
  for (let i = 0; i < bytes.length; i++) text += String.fromCharCode(bytes[i]);
  return JSON.parse(text);
}

async function verifyAppUser(request, env) {
  const header = request.headers.get('authorization') || '';
  const [scheme, token] = header.split(' ');
  if (scheme !== 'Bearer' || !token) return null;
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const [h, p, s] = parts;
    if (!h || !p || !s) return null;
    const decodedHeader = b64urlToJson(h);
    if (
      !decodedHeader ||
      decodedHeader.alg !== 'ES256' ||
      typeof decodedHeader.kid !== 'string' ||
      !decodedHeader.kid
    ) {
      return null;
    }
    const jwk = await getJwk(decodedHeader.kid);
    if (!jwk || (jwk.alg && jwk.alg !== decodedHeader.alg)) return null;
    const key = await crypto.subtle.importKey(
      'jwk',
      jwk,
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['verify'],
    );
    const data = new TextEncoder().encode(`${h}.${p}`);
    const sig = b64urlToBytes(s);
    const ok = await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      key,
      sig,
      data,
    );
    if (!ok) return null;
    const payload = b64urlToJson(p);
    const now = Math.floor(Date.now() / 1000);
    const audience = payload.aud;
    if (
      !Number.isFinite(payload.exp) ||
      payload.exp <= now ||
      payload.iss !== JWT_ISSUER ||
      (audience !== 'authenticated' &&
        !(Array.isArray(audience) && audience.includes('authenticated'))) ||
      payload.role !== 'authenticated' ||
      ('nbf' in payload &&
        (!Number.isFinite(payload.nbf) || payload.nbf > now))
    ) {
      return null;
    }
    return typeof payload.sub === 'string' && payload.sub ? payload.sub : null;
  } catch (_) {
    return null;
  }
}

/** Posts the report to Discord with the log itself attached, so reading one is
 *  a click rather than a fetch from storage. */
async function notify(
  env,
  { ref, version, device, form, sources, mode, country, note, key, body },
) {
  // Checked properly rather than for truthiness: `wrangler secret put` will
  // happily store an empty string if the paste didn't register at the prompt,
  // and that looks identical to "not configured" from in here. The LENGTH is
  // logged, never the value — it is a credential.
  const hook = (env.DISCORD_WEBHOOK || '').trim();
  if (!hook.startsWith('https://discord.com/api/webhooks/')) {
    console.warn(
      `DISCORD_WEBHOOK unusable (length ${hook.length}); ` +
        `${ref} stored but nobody told`,
    );
    return;
  }

  // Pulled out of the log so the notification itself says what broke — the
  // attachment is for when you need the rest.
  const errors = await lastErrors(body);

  const lines = [
    `**Log report \`${ref}\`**`,
    `\`${device || 'unknown'}\`${form ? ` · ${form}` : ''}` +
      `${country ? ` · ${country}` : ''}`,
    `app ${version || '?'}${mode ? ` · ${mode}` : ''}` +
      `${sources ? ` · ${sources}` : ''} · ${(body.byteLength / 1024).toFixed(0)}KB`,
    note ? `> ${note}` : null,
    errors ? `\`\`\`\n${errors}\n\`\`\`` : null,
    `-# kv \`${key}\` · kept 30 days`,
  ].filter(Boolean);

  const payload = new FormData();
  payload.append(
    'payload_json',
    JSON.stringify({
      username: 'Zangetsu logs',
      // The note is user-supplied — never let a report ping the channel.
      allowed_mentions: { parse: [] },
      content: lines.join('\n'),
    }),
  );
  payload.append('files[0]', new Blob([body]), `${ref}.log.gz`);

  const res = await fetch(hook, { method: 'POST', body: payload });

  // fetch() does NOT throw on a 4xx, so a deleted webhook or a wrong URL would
  // otherwise fail completely silently — reports piling up in KV with nobody
  // told. Say so where `wrangler tail` can see it.
  if (res.ok) {
    console.log(`discord accepted ${ref}: ${res.status}`);
  } else {
    console.warn(
      `discord rejected ${ref}: ${res.status} ${(await res.text()).slice(0, 300)}`,
    );
  }
}
