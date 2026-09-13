# Log intake Worker

Receives the diagnostic log the app sends when someone taps **Settings → Share
logs**, posts it to a Discord channel with the log attached, and keeps a copy in
KV for 30 days.

Deployed at `https://zangetsu-logs.log-intake.workers.dev` — that URL is
in `kLogIntakeUrl` (`lib/core/app_config.dart`).

The app only knows that URL. The Discord webhook lives on the Worker, because
the APK is public and the source is GPL — anything embedded in the app can be
pulled straight back out of it.

It also means a user whose network blocks Discord is unaffected: their app talks
to Cloudflare, and Discord is called from here.

## Why KV and not R2

R2 requires a payment method on file even on its free tier, and a 25KB gzipped
log has no use for R2's headroom. KV is free with no card, expires entries
itself (no lifecycle rule to configure), and its 25MB per-value limit is a
thousand times what a report needs.

## Gotcha: editing in the dashboard pins the deployment

After changing anything from the Cloudflare dashboard (a secret, for instance),
`wrangler deploy` keeps uploading versions but the live one stops moving. Check
with `wrangler deployments status`, and promote by hand:

```bash
npx wrangler versions deploy <version-id>@100% --yes
```

A `workers.dev` hostname can also serve a stale build long after a deploy —
`/health` returns a `build` marker so you can tell. Bumping `BUILD` in
`src/index.js` and renaming the Worker forces a fresh hostname if it sticks.

## Still to do

**Set the Discord webhook.** Until this is set the Worker stores reports but
tells nobody:

```bash
cd cloudflare/log-intake
npx wrangler secret put DISCORD_WEBHOOK
```

Get the value from Discord: your server → a **private** channel → Edit Channel →
Integrations → Webhooks → New Webhook → Copy Webhook URL. Reports are diagnostic
logs, so keep that channel private.

**Add a rate limit.** Dashboard → your Worker → Settings → or WAF → Rate
limiting rules: cap `/v1/logs` at ~10 requests per minute per IP. The Worker
caps body size, but nothing stops someone posting repeatedly without this.

## Redeploying

```bash
cd cloudflare/log-intake
npx wrangler deploy
```

## API

`POST /v1/logs`

| | |
|---|---|
| body | gzipped log bytes, max 1MB |
| `X-App-Version` | e.g. `2.0.0+13108` |
| `X-Device` | e.g. `android 15` |
| `?note=` | optional, what the user typed |

Returns `{"ref":"K7M2QX"}` — six characters shown to the user so a report can be
matched to a person. Generated on the Worker, not the client, so two reports
can't collide and nobody can overwrite someone else's.

`GET /health` → `{"ok":true}`

## Reading a report

Click the attachment on the Discord message — that is the intended path and it
is already the gzipped log.

The KV copy is a backup for when Discord was down when the report arrived.
Reading it from the CLI is awkward because `wrangler kv key get` only writes
text, which mangles gzip. List them, then pull one through the dashboard
(Storage & Databases -> KV -> LOGS), or just re-send:

```bash
npx wrangler kv key list --binding LOGS --remote
```

The metadata in that listing — device, sources, mode, country, note — is often
enough on its own to know what you are looking at.
