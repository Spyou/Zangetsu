# WATCH_APP — Design Spec

**Date:** 2026-05-30
**Status:** Approved (design); pending implementation plan
**Working name:** `WATCH_APP` (placeholder — final name TBD, see §1)

## Summary

WATCH_APP is a new, standalone Flutter anime streaming app — a sibling to the
existing manga/novel reader "Sozo Read", **not** a feature of it. The two apps
stay fully independent: we **port/adapt** Sozo Read's proven, source-agnostic
architecture (the JS provider + hosted-repo "extension" system) into a fresh
project; we do **not** add a dependency on the Sozo Read codebase.

Anime is the first content type. The data model is designed so movies fit later,
but no movie-specific UI is built in this scope.

### Decisions locked during brainstorming

| Topic | Decision |
|---|---|
| App relationship | Separate standalone app; port/adapt, no shared dependency |
| Framework / playback | Flutter; `media_kit` for video |
| Subs vs dubs | Tagged video sources + tracks (each `VideoSource` carries `kind:'sub'/'dub'`, `audioLang`, `subtitles[]`) |
| Manifest | New **versioned schema v2** with an app/kind guard |
| Scaffold | Port layout selectively into the existing fresh `watch_app/` project |
| Domain vocabulary | Video-native: **Media / Episode / VideoSource** |
| Extractors | Hosted, registered extractor registry on GitHub — same mechanism as providers |
| v1 scope | Everything: core + library + history + theming + downloads + sync + notifications (sequenced into phases) |

## Reference architecture (what we port from Sozo Read)

The content layer in Sozo Read is already source-agnostic. The repo / registry /
runtime machinery has **zero** manga-specific logic — `type` is just a string.
The only manga-specific leaves are `getPages` (image URLs) and the reader UI.

Ported as-is (conceptually):

- **Single QuickJS runtime, routed by `sourceId`.** `flutter_js` binds one
  message channel per name (last-writer-wins), so multi-runtime designs deadlock.
  One runtime hosts every provider at `globalThis.__providers[sourceId]`; every
  call/fetch carries its `sourceId` in the payload.
- **JS bootstrap** — async `__fetch` bridge (JS → `sendMessage('fetch')` → Dart
  Dio → `__resolveFetch`), `__console`, `__callProvider`, shared scraping helpers
  (`htmlText`, `absUrl`, `btoa`). `wrapProviderSource()` wraps each provider in an
  IIFE with a local `fetch`/`console` bound to its `sourceId`.
- **ProviderManager / `_JsHost`** — owns the runtime + Dio fetch handler,
  per-source health (healthy → degraded → broken at 3 fails), 15s call timeout,
  **no host mutex** (QuickJS serializes at FFI; a past mutex stalled search).
- **ProviderRegistry** — Hive box keyed by composite `repoUrl::sourceId` so two
  repos can ship the same id; install/uninstall/enable, JS download+cache,
  runtime load; one provider per `sourceId` live at a time, swapped via
  `setRuntimeActive`.
- **ProviderReposRegistry** — Aniyomi/Cloudstream repo discovery: a repo = a
  hosted `index.json` manifest, cached in Hive, auto-refreshed at launch +
  pull-to-refresh, relative `file` joined against the manifest dir, default repo
  seeded on first launch, `customName` override survives refreshes.

What changes (only the two leaf layers + a new extractor layer):
`getPages` → `getVideoSources`; reader UI → `media_kit` player; **add** a hosted
per-host extractor subsystem.

---

## 1. Project identity & rename strategy

- Keep the existing fresh `watch_app/` Flutter project. Pubspec `name` stays
  `watch_app`.
- **Single rename point:** `lib/core/app_config.dart` exposing
  `const kAppName = 'WATCH_APP';`. All UI strings that show the product name read
  `kAppName`. Final rename = one find/replace on the token `WATCH_APP` plus a
  bundle-id rename (`flutter pub run rename` or manual `android`/`ios` edits).
  Documented in the README.

## 2. Provider contract (video)

Each anime provider is a self-contained `.js` exposing these globals:

```js
getInfo()                       // { name, lang, baseUrl, logo, type:'anime', version }
search(query, page, opts)       // -> [MediaItem]   (opts.category optional)
getDetail(url)                  // -> MediaDetail { ..., episodes:[Episode] }
getEpisodes(seriesUrl)          // -> [Episode]      (replaces getChapters)
getVideoSources(episodeUrl)     // -> [VideoSource]  (replaces getPages)
getSettings()                   // optional, unchanged from Sozo
```

`search` / `getDetail` / `getEpisodes` are conceptually identical to the manga
equivalents. Only the final step differs.

## 3. Data models (video-native)

```
MediaItem    { id, sourceId, title, cover, coverHeaders?, url, type:'anime' }
MediaDetail  { ...MediaItem, description, status, genres[], studios[],
               episodes:[Episode] }
Episode      { id, title, number?, url, date?, thumbnail?, filler? }
VideoSource  { url, quality:'1080p', type:'hls'|'mp4', headers:{Referer,...},
               kind:'sub'|'dub', audioLang:'ja', subtitles:[Subtitle] }
Subtitle     { url, lang:'en', label:'English', format:'vtt'|'srt', default? }
```

Wire shape stays close to Sozo's where it costs nothing (Episode keeps
`id/title/number/url/date` like Chapter) so the JS bridge + host port ~1:1.
Dart models mirror Sozo's `@JsonSerializable` + `Equatable` style.

## 4. Extractor subsystem (hosted on GitHub, same mechanism as providers)

Embed hosts (Doodstream, Streamtape, Filemoon, …) are the real ongoing
maintenance work, so they are **independently updatable hosted modules**, not
app-bundled code.

- Each extractor is a `.js` module:
  ```js
  getInfo()          // { id, name, version, hosts:['dood.to','dood.la', ...] }
  extract(url, opts) // -> [VideoSource]   (one or more qualities)
  ```
- Loaded into the **same QuickJS runtime**, registered as `__extractors[hostAlias]`
  for each alias in `hosts`.
- New shared bootstrap helper **`extractVideo(embedUrl, opts)`** parses the URL
  host and dispatches to the matching extractor. Providers call
  `extractVideo(embedUrl)` inside `getVideoSources` and return resolved sources —
  extraction is written once, shared by every provider.
- Fetched / cached / version-updated through the **same registry + downloader
  path** as providers (an `ExtractorRegistry` parallel to `ProviderRegistry`, or
  one registry keyed by module type).
- Hosted in the same GitHub repo as providers; updating a broken host = push one
  `.js` file, picked up on next app launch. No app update, no provider edits.

## 5. Manifest schema v2

```json
{
  "schemaVersion": 2,
  "appId": "watch_app",
  "kind": "video",
  "name": "WATCH_APP Default Sources",
  "description": "Default anime sources + extractors for WATCH_APP.",
  "sources": [
    {
      "id": "example-anime", "name": "Example", "version": "1.0.0",
      "type": "anime", "lang": "en", "file": "providers/example.js",
      "logo": "https://.../logo.png", "nsfw": false,
      "subs": true, "dubs": true
    }
  ],
  "extractors": [
    {
      "id": "doodstream", "name": "Doodstream", "version": "1.0.0",
      "file": "extractors/doodstream.js",
      "hosts": ["dood.to", "dood.la", "doodstream.com"]
    }
  ]
}
```

- **Guard:** on add-repo, the app checks `schemaVersion >= 2` and matching
  `appId`/`kind` (or presence of `type` in `{anime, movie}`), and refuses/warns
  on a manga-only (Sozo v1) repo. Cross-app safety.
- `subs`/`dubs` on a source are **display hints only**; the authoritative sub/dub
  data lives in `VideoSource` returns (see §3).
- `type` accepts `anime` now, `movie` later — no further schema change needed for
  movies.

## 6. Player feature module (`media_kit`)

Replaces the reader. v1 capabilities:

- HLS / m3u8 + progressive mp4.
- **Custom headers** (Referer / User-Agent from `VideoSource.headers`) threaded
  into `media_kit` playback.
- **Soft subtitles** — multi-track vtt/srt selection + basic styling.
- **Sub/dub + quality switching** across the `VideoSource` list (and HLS variant
  ladders where present).
- **Resume position** persisted per (sourceId, episode).
- Playback speed, seek/gesture controls, next-episode autoplay.
- **DRM detection → skip** Widevine / ClearKey sources with a clear message.

Deferred (easy later adds): PiP, casting, skip-intro/outro markers.

## 7. Ported subsystems (all in v1, sequenced)

Ported from Sozo's patterns, adapted to episodes/video:

- **Library + watch status** — add/track titles; watching / completed /
  plan-to-watch.
- **History + continue-watching** — resume positions and a "next unwatched
  episode" row.
- **Theming / onboarding shell** — port Sozo's theme + onboarding; basis for the
  frontend-design UI work.
- **Downloads** — quality tiers, larger files, header-aware, background/resumable.
- **Supabase magic-link sync** — cross-device library/history/progress sync.
- **New-episode notifications** — new-content checks adapted to episodes.

## 8. Providers GitHub repo (`watch-app-providers`)

```
index.json                 # v2 manifest
providers/*.js             # anime sources
extractors/*.js            # per-host extractors
_template.js               # provider template
_extractor_template.js     # extractor template
README.md
```

Seeded as the default repo on first launch. A **bundled dev anime provider**
ships in-app to drive the first vertical slice before the GitHub repo is live.

## 9. Known hard parts — handling

- **Embed / obfuscated m3u8** → isolated in extractor modules, hot-updatable.
- **Strict Referer / headers** → carried on `VideoSource.headers`, applied in
  **both** playback and downloads.
- **Widevine DRM** → detected and skipped (no DRM support in scope).
- **Big downloads / quality tiers** → `quality` is first-class; downloads pick a
  tier and persist headers for resumable fetches.

## Build phasing (order, not scope cuts)

| Phase | Deliverable |
|---|---|
| **P0** | Scaffold: deps (`flutter_js`, `media_kit`, `dio`, `hive`, `supabase`, …), package layout, `app_config.dart` |
| **P1** | Provider runtime + video contract + models + **bundled dev provider**; vertical slice search → detail → episodes → sources |
| **P2** | Extractor subsystem + `extractVideo` + 1–2 real extractors |
| **P3** | `media_kit` player module (the meat): HLS, headers, subs, quality/sub-dub switch, resume, DRM skip |
| **P4** | Repos UI + manifest v2 + guard + `watch-app-providers` GitHub repo |
| **P5** | Library + watch status + history/continue-watching + theming |
| **P6** | Downloads (quality tiers, header-aware, background) |
| **P7** | Supabase magic-link sync + new-episode notifications |

The **frontend-design** plugin drives UI polish across P3–P7.

## Out of scope (this spec)

- Movie-specific UI (model supports it; UI later).
- DRM-protected playback.
- PiP / casting / skip-intro markers (post-v1).
- Any shared code dependency on the Sozo Read repo.
