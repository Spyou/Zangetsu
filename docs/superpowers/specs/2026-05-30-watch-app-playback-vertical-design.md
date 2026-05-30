# WATCH_APP — First Real Playback Vertical — Design Spec

**Date:** 2026-05-30
**Status:** Approved (design); pending implementation plan
**Builds on:** P0/P1 foundation (content runtime, models, extractor registry) — see
`2026-05-30-watch-app-design.md`.

## Summary

The first end-to-end vertical that plays a **real** anime episode: a real
**AllAnime** provider feeds the full-featured `media_kit` player through minimal
**Search → Detail/Episodes → Player** screens. This replaces the throwaway
dev-slice and proves the whole stack on real content.

### Decisions locked during brainstorming

| Topic | Decision |
|---|---|
| First real source | **AllAnime** (`api.allanime.day`) — scraper-friendly, often direct `.m3u8`/`.mp4`; ani-cli's default |
| UI polish | **Functional first** (clean-but-simple screens); dedicated frontend-design pass later |
| Player scope | **Full** P3 feature set (sub/dub + quality switching, soft subs, audio tracks, resume, autoplay-next, gestures, DRM-skip) |
| Extractor | **None new for v1** — AllAnime decoded links are direct, so the provider self-resolves; the P1 extractor registry stays ready for embed-host sources in P2 |

## Architecture (unchanged foundation)

Reuses P0/P1 verbatim: single shared QuickJS runtime (`ProviderManager`), the
video provider contract (`getInfo/search/getDetail/getEpisodes/getVideoSources`),
the video-native models (`MediaItem/MediaDetail/Episode/VideoSource/Subtitle`),
and the bundled-load path. New work is additive: a real provider, the player
feature, and minimal navigation UI.

---

## 1. AllAnime provider (`providers/allanime.js`, bundled)

A real provider implementing the existing JS contract against AllAnime's public
API.

- **Endpoint/headers:** `https://api.allanime.day/api`, with
  `Referer: https://allanime.to` and a desktop `User-Agent`. Queries are sent as
  GET with `variables` + persisted-query `query` params (the ani-cli shape).
- **`getInfo`** → `{ name:'AllAnime', lang:'en', baseUrl, type:'anime', version }`.
- **`search(query, page, opts)`** → `shows` query → `[MediaItem]`
  (`id`=show `_id`, `title`, `cover` = `thumbnail`, `url` carries the show id).
- **`getDetail(url)` / `getEpisodes(url)`** → `show` query →
  `availableEpisodesDetail` (separate **sub** and **dub** episode lists) →
  `[Episode]` (number, id). Detail also returns description/genres/status when
  present.
- **`getVideoSources(episodeUrl)`** → **persisted-query GET** of the `episode`
  operation (hash `d405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec`).
  The response is **AES-256-CTR encrypted** under `data.tobeparsed` (base64) —
  verified live 2026-05-30; there is no plain/hex-only path anymore. The provider:
  1. **Decrypts** `tobeparsed` → `episode.sourceUrls[]` (see §1.5 crypto). Verified
     params: `key = SHA256("Xot36i3lK3:v1")`, `iv = blob[1..13]`,
     `counter = iv ‖ 0x00000002`, `ciphertext = blob[13 .. len-16]`.
  2. For each `sourceUrl`: if it starts with `--`, **hex-substitution decode**
     (ani-cli table) → `/apivtwo/clock.json?id=…`; fetch
     `https://allanime.day<path>` (Referer `https://youtu-chan.com`) → `links[]`
     (`link` + `resolutionStr` + `hls`) → emit a `VideoSource` per link, `quality`
     from `resolutionStr`, `container:'hls'|'mp4'` (HLS master playlists are
     handed to media_kit as-is for its own variant ladder). Direct `https://`
     `sourceUrl`s (e.g. `Yt-mp4` → `tools.fast4speed.rsvp`) emit directly.
  3. **Embed-host** `sourceName`s (`Ok`/ok.ru, `Ss-Hls`/streamsb, `Mp4`/mp4upload,
     `Sl-mp4`/streamlare) are **skipped in v1** (they need per-host extractors —
     deferred to P2). `Default`/`S-mp4`/`Uv-mp4`/`Luf-Mp4` + `Yt-mp4` give enough
     direct playable streams.
  - Every emitted source carries `headers` (`Referer: https://youtu-chan.com`,
    desktop UA) and `kind:'sub'|'dub'` (from which episode list it came).
- **Stability note:** AllAnime rotates its API host, persisted-query hash, the
  `Referer` host (`youtu-chan.com`), and the AES key string over time. The provider
  hard-codes current values; when they drift the fix is a one-file JS update (the
  point of the hosted-provider model). The live integration test catches drift.
  Bundled now, moves to the hosted repo in P4.

## 1.5 Runtime crypto capability (NEW — required by AllAnime)

QuickJS has no WebCrypto, but AllAnime (and future embed hosts like MegaCloud)
require real crypto. Add a **Dart-backed async crypto bridge** to the runtime,
mirroring the existing `fetch` bridge:

- JS host helpers exposed to providers/extractors:
  `sha256Hex(message) → Promise<hex>` and
  `aesCtrDecrypt({keyHex, counterHex, dataB64}) → Promise<plaintextUtf8>`.
- Dart side: `crypto` package (SHA-256, already a dep) + `pointycastle` (AES-CTR)
  handle a new `crypto` message channel.
- The Node test harness mirrors these with `node:crypto` (already proven to decrypt
  the live blob), so providers test identically offline and on-device.
- Pure-JS helpers (`base64ToBytes`, byte/hex slicing) stay in JS; only SHA-256 and
  AES go through the bridge. General primitives (not AllAnime-specific) so P2
  extractors reuse them.

## 2. Extractor stance (v1)

AllAnime's decoded links are predominantly **direct** streams, so the provider
self-resolves and **no new per-host extractor is built for this vertical** (YAGNI).
The `__extractors` registry + `extractVideo` dispatcher from P1 remain in place,
unit-proven, and get exercised against real embed hosts (Doodstream/Streamtape via
Gogoanime etc.) in P2.

## 3. `media_kit` player module (`lib/features/player/`)

Built on `media_kit` + `media_kit_video`. `media_kit_video`'s
`MaterialVideoControls` provides play/pause/seek/fullscreen/subtitle/audio-track
UI out of the box; we extend it with the app-specific pieces.

- **Deps:** `media_kit`, `media_kit_video`, `media_kit_libs_video`. (iOS/macOS
  pull a CocoaPods pod — CocoaPods is now working.)
- **Playback:** HLS (`.m3u8`) + progressive `.mp4`; **custom headers**
  (`Referer`/`User-Agent` from `VideoSource.headers`) passed via
  `Media(url, httpHeaders: …)`.
- **Source selection:** given the `VideoSource[]` for an episode, group by
  `kind` (sub/dub) and `quality`; expose a **sub/dub toggle** and a **quality
  picker**; switching re-opens the player at the saved position.
- **Tracks:** **soft subtitles** (load `Subtitle[]` as external tracks) +
  **audio-track** selection where the stream is multi-audio.
- **Resume:** persist position per `(sourceId, episodeId)` in Hive
  (`lib/core/playback/resume_store.dart`); seek there on open; save on
  pause/dispose/throttled ticks.
- **Autoplay-next:** on completion (or a "Next" control), advance to the next
  episode in the list and start playback.
- **Gestures:** vertical drags for volume (right) / brightness (left), horizontal
  drag/double-tap to seek.
- **DRM-skip:** detect Widevine/ClearKey signals on a source and skip it with a
  clear message (no DRM support in scope).

## 4. Minimal UI & navigation (`lib/features/{home,detail}/`)

- **Home:** a search field + results grid (`MediaItem` covers with headers).
- **Detail:** poster/title/description, a **sub/dub** toggle, and the **episode
  list**; tapping an episode resolves `getVideoSources` and opens the player.
- **Navigation:** plain `Navigator.push` for now (defer `go_router` until
  deep-linking/sync needs it).
- **State:** a thin `SourceRepository` (`lib/core/repository/source_repository.dart`)
  wraps `ProviderManager`; screens use `FutureBuilder`/lightweight Cubits — no
  heavy bloc yet.
- **Entry:** `main.dart` launches `HomeScreen` (the dev-slice is removed).

## 5. Structure

```
lib/
  core/
    repository/source_repository.dart      # search/detail/episodes/sources over ProviderManager
    playback/resume_store.dart             # Hive-backed resume positions
  features/
    home/      home_screen.dart            # search + results
    detail/    detail_screen.dart          # poster + sub/dub + episodes
    player/    player_screen.dart          # media_kit player
               player_controller.dart      # source/quality/track/resume/autoplay logic
providers/allanime.js                      # real AllAnime provider (bundled)
```

## 6. Testing

- **Decode unit tests** — the AllAnime `sourceUrl` decode verified with known
  input→output vectors (deterministic; Node and/or Dart).
- **Live integration test (network-gated)** — a Node test hitting the real
  AllAnime API: `search → episodes → getVideoSources` returns at least one
  playable `.m3u8`/`.mp4`. Skipped by default so the offline suite stays green;
  run explicitly.
- **Player logic unit tests** — source grouping, quality sort, sub/dub
  selection, resume read/write (no real playback).
- **On-device smoke** — actually watch a real episode end-to-end (now unblocked).

## 7. Build phasing — split into two plans

This vertical is two independent, separately-testable subsystems, so it gets two
implementation plans:

**Plan 2A — data layer (AllAnime provider + crypto bridge).** Deliverable:
`getVideoSources('…')` returns real playable `.m3u8`/`.mp4` URLs.
- A1: Dart-backed crypto bridge (`sha256Hex`, `aesCtrDecrypt`) + Node harness mirror.
- A2: AllAnime provider (search/episodes POST; sources persisted-GET → decrypt →
  hex-decode → clock resolve), with hex-decode + AES unit tests and a network-gated
  live integration test.

**Plan 2B — presentation (player + UI), depends on 2A.** Deliverable: watch a real
episode on-device.
- B1: `media_kit` player module (full features), driven by example data first.
- B2: `SourceRepository` + Home (search) + Detail (sub/dub + episodes) → open Player.
- B3: resume + autoplay-next + DRM-skip; on-device smoke — watch a real AllAnime
  episode end-to-end.

## Out of scope (this vertical)

- New per-host extractors (P2), the hosted providers repo + manifest v2 guard (P4).
- Library / watch-status / history beyond per-episode resume (P5).
- Downloads (P6), Supabase sync, notifications (P7).
- Dedicated frontend-design polish pass (separate follow-up).
- `go_router` / deep links / DRM playback / casting / PiP.
