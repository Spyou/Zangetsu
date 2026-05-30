# WATCH_APP — P2: Real Embed Extractors — Design Spec

**Date:** 2026-05-30
**Status:** Approved (design); pending implementation plan
**Builds on:** the playback vertical (2A/2B, on `main`) and the extractor subsystem
designed in `2026-05-30-watch-app-design.md` §4 (hosted `__extractors[host]` +
`extractVideo(embedUrl, opts)` dispatcher, already built + unit-proven in P1).

## Summary

Implement **real per-host extractors** for the embed hosts AllAnime returns that
we currently **skip**, plus one broadly-useful host. Each extractor is a JS module
(`extractors/<host>.js`) implementing `getInfo()` + `extract(url, opts)`, registered
under its domains in `__extractors` and reached via the existing `extractVideo`
dispatcher. AllAnime's `getVideoSources` is rewired to route embed-host sources
through `extractVideo` instead of dropping them — directly adding playable streams
per episode (and reducing the dead-source failures seen in 2B on-device testing).

### Scope (decided from parallel host research, 2026-05-30)

Ship four extractors — all **browser-free** (HTTP fetch + parse only; runnable in
the QuickJS provider runtime) and needing **no crypto** (so the AES bridge from 2A
is not used here):

| Extractor | AllAnime source | Output | Playback headers | Notes |
|---|---|---|---|---|
| **okru** | `Ok` | mp4 (multi-quality) + HLS master | UA only (no Referer needed) | easiest, live-verified |
| **mp4upload** | `Mp4` | progressive mp4 | `Referer: https://www.mp4upload.com/` + UA | Dean-Edwards packer unpack |
| **streamlare** | `Sl-mp4` | HLS master / mp4 | `Referer: https://slwatch.co/` + UA | flaky from datacenter IPs; fine from a phone's residential IP |
| **doodstream** | (none today; broad) | mp4 (token URL) | `Referer: https://<doodHost>/` + UA | for future providers; domains rotate |

**Explicitly out of scope:** `streamsb`/`Ss-Hls` (host **dead** since 2023, code
DMCA'd — `Ss-Hls` entries stay skipped) and **megacloud** (HiAnime collapsed Mar
2026, key feed DMCA'd, needs an external rotating key not derivable in a
regex/crypto sandbox — defer to a future HiAnime provider if the ecosystem
recovers; it would also require an MD5 + AES-CBC addition to the crypto bridge).

## Architecture (reused, unchanged)

P1's extractor subsystem is the substrate: `wrapExtractorSource` registers each
module under every domain in its `getInfo().hosts`; providers call
`extractVideo(embedUrl, {headers})`, which parses the URL host and dispatches to
`__extractors[host].extract(...)`. Extractors return `[VideoSource]` (same model
as providers). No runtime changes needed beyond loading the new modules.

One shared helper is added to the JS bootstrap: a **Dean-Edwards packer unpacker**
(`unpackJs(str)`, pure base-62, no eval) — needed by mp4upload and reusable by
future hosts. It joins `htmlText`/`absUrl` as a host global.

---

## 1. Extractor module contract (per `extractors/<host>.js`)

```js
getInfo()            // { id, name, version, hosts:[<domain>, ...] }
extract(url, opts)   // -> [VideoSource]   (opts.headers = caller's default headers)
```
`VideoSource` fields (existing model): `{ url, quality, container:'hls'|'mp4',
headers, kind, audioLang, subtitles[] }`. Extractors set `url`/`quality`/
`container`/`headers`; `kind`/`audioLang` are passed through from `opts` (the
provider knows sub/dub), defaulting sanely; `subtitles` only if the host exposes them.

## 2. Per-host extraction (implementation ground-truth)

**okru** (`extractors/okru.js`) — hosts: `ok.ru`, `www.ok.ru`, `m.ok.ru`,
`mobile.ok.ru`, `odnoklassniki.ru`, `www.odnoklassniki.ru`.
1. `GET embedUrl` (browser UA, no Referer).
2. Regex `data-options="([^"]*)"`; `.replace(/&quot;/g,'"').replace(/&amp;/g,'&')`; `JSON.parse`.
3. `meta = JSON.parse(opts.flashvars.metadata)`.
4. HLS: `meta.hlsMasterPlaylistUrl || meta.hlsManifestUrl || meta.ondemandHls` → one `container:'hls'` source.
5. MP4: for each `meta.videos[]` → `{url, quality: Q[name]}` with `Q = {mobile:'144p',lowest:'240p',low:'360p',sd:'480p',hd:'720p',full:'1080p',quad:'1440p',ultra:'2160p'}`, `container:'mp4'`.
6. Headers: `{User-Agent}` only. URLs are IP-pinned + expiring — resolve just-in-time.

**mp4upload** (`extractors/mp4upload.js`) — hosts: `mp4upload.com`, `www.mp4upload.com`.
1. `GET embedUrl` with `Referer: https://mp4upload.com/` + UA.
2. Find the packer `<script>` (`eval(function(p,a,c,k,e,d)`); `unpackJs()` it (shared helper). Fall back to raw HTML (AllAnime-proxied pages expose `src:` in clear).
3. URL: regex `player\.src\("([^"]+)"` or `src:\s*"([^"]+)"`.
4. Quality: `[^A-Za-z0-9]HEIGHT=(\d+)` → `'<n>p'`, else `'auto'`.
5. `container:'mp4'`; playback headers `{Referer: https://www.mp4upload.com/, User-Agent}` (CDN 403s without Referer; keep the `:282` port in the URL).

**streamlare** (`extractors/streamlare.js`) — hosts: `streamlare.com`, `slwatch.co`,
`slmaxed.com`, `sltube.org`, `streamlare.cc`.
1. `id` = last path segment of the embed URL (`/[ve]/(...)`).
2. `POST https://slwatch.co/api/video/stream/get` `Content-Type: application/json`, body `{"id":"<id>"}`, `Referer: https://slwatch.co/` + UA.
3. If body isn't JSON (anti-bot interstitial) → throw (handled gracefully upstream).
4. Parse JSON; iterate `result` (a **map keyed by label**). HLS entry (`type` contains `hls`) → `container:'hls'`, `url = file` (un-escape `\/`). mp4 entry → `file` is a redirect stub; emit it (player follows redirect) or POST+follow `Location`.
5. Headers `{Referer: https://slwatch.co/, User-Agent}`.

**doodstream** (`extractors/doodstream.js`) — hosts: many rotating
(`dood.to/la/ws/so/li/cx/sh/wf/yt/pm/re/watch/work`, `doodstream.com`,
`d000d.com`, `d0000d.com`, `dooood.com`, `ds2play.com`, `ds2video.com`,
`vide0.net`, `doods.pro`, `dsvplay.com`, …) — match the `dood`-family loosely.
1. Normalize `/d/`→`/e/`; `GET` following redirects; derive `host` from the **final** URL.
2. Require `'/pass_md5/` in HTML; regex `/pass_md5/[^']*` → `md5Path`; `token = md5Path.substringAfterLast('/')`.
3. `GET host+md5Path` with `Referer: <finalEmbedUrl>` → body is a plain base URL (trim).
4. Final mp4 = `<base> + <10 random alnum> + '?token=' + token + '&expiry=' + Date.now()`.
5. `container:'mp4'`, headers `{Referer: https://<host>/, User-Agent}` (mandatory for playback). Time-limited — resolve just-in-time. (QuickJS has `Math.random`/`Date.now`; both fine in the provider runtime.)

## 3. AllAnime wiring change (`providers/allanime.js`)

`getVideoSources` currently `continue`s past the embed-host sourceNames
(`{Ok, Ss-Hls, Mp4, Sl-mp4}`). Change: for **`Ok`/`Mp4`/`Sl-mp4`**, the `sourceUrl`
is already a direct embed URL (e.g. `https://ok.ru/videoembed/…`) — route it through
`extractVideo(rawUrl, {headers:{Referer,User-Agent}})` (each wrapped in `.catch(()=>[])`,
like the clock jobs, so a failing host never sinks the others). Keep **`Ss-Hls`
skipped** (dead). The decoded `--`/clock path is unchanged.

## 4. Bundling

Like the example extractor: each `extractors/<host>.js` is a pubspec asset, loaded
at startup in `injector.dart` via `manager.loadExtractor(extractorId, jsSource)`.
(They move to the hosted repo in P4 alongside the providers.) The shared
`unpackJs` helper lives in `kJsBootstrap` (a host global, like `htmlText`).

## 5. Testing

Per the Node harness pattern (`js_harness/`):
- **Deterministic unit tests** per extractor against **saved HTML/JSON fixtures**
  (so they don't depend on a live host): okru `data-options` parse, mp4upload
  packer-unpack + `src` regex, streamlare JSON-result mapping, doodstream
  pass_md5 → final-URL construction. Plus a unit test for the shared `unpackJs`
  with a known packed→unpacked vector.
- **Network-gated live tests** (`RUN_LIVE=1`), one per host, that resolve a real
  embed to a playable URL — skipped by default (hosts are flaky/rotating).
- **End-to-end (live-gated):** AllAnime `getVideoSources` for an episode now
  returns extractor-resolved sources for `Ok`/`Mp4`/`Sl-mp4` in addition to the
  clock/direct ones.
- Dart side: `flutter analyze` + existing 20 tests stay green (no Dart logic
  changes beyond possibly loading the new assets).

## 6. Build phasing (one plan; naturally parallel)

The four extractors are independent → built in parallel (one agent each), each
TDD'd against fixtures in the Node harness. Then the AllAnime wiring + bundling +
the shared `unpackJs` helper. Order: shared `unpackJs` helper → 4 extractors
(parallel) → AllAnime wiring → bundling + injector → live end-to-end check →
on-device smoke (more sources play per episode).

## Out of scope (this phase)

- streamsb (dead), megacloud (offline/hard; future HiAnime provider + MD5/AES-CBC
  bridge addition).
- The hosted providers/extractors GitHub repo + manifest-v2 guard (P4) — extractors
  stay bundled for now.
- Faster source resolution / early-return UX (separate follow-up).
- Any new provider beyond AllAnime.
