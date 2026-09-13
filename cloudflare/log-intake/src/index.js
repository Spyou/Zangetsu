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
 *   DISCORD_WEBHOOK secret — `wrangler secret put DISCORD_WEBHOOK`
 */

/** Refuse anything bigger. A full log is ~25KB gzipped; this is for a
 *  malformed client or someone poking at the endpoint. Also comfortably under
 *  Discord's attachment limit. */
const MAX_BYTES = 1_000_000;

/** Bumped by hand when the Worker changes, so `/health` can prove which code
 *  is actually serving. Cloudflare takes a while to roll a new version out and
 *  there is otherwise no way to tell from outside. */
const BUILD = 'ctx-1';

/** Long enough to still have the log when someone gets round to mentioning it,
 *  short enough that nothing accumulates. KV expires these itself. */
const KEEP_SECONDS = 60 * 60 * 24 * 30;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, X-App-Version, X-Device',
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
