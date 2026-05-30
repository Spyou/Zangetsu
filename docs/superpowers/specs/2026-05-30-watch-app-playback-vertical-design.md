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
- **`getVideoSources(episodeUrl)`** → `episode` query → `sourceUrls[]`. Each
  `sourceUrl` is obfuscated (prefix `--` + substitution/hex encoding). The
  provider **ports ani-cli's decode algorithm**, then:
  - direct links → return as `VideoSource` (`container` sniffed from extension);
  - `clock`-style links → fetch the resolver JSON (`/apivtwo/clock?id=…` →
    `links[]` with `link` + `resolutionStr`/`hls`) → return each as a
    `VideoSource` tagged `quality` + `container:'hls'|'mp4'`.
  - Every source carries `headers` (Referer/UA) and `kind:'sub'|'dub'` (from
    which episode list it came), plus any `subtitles[]` AllAnime exposes.
- **Stability note:** AllAnime occasionally rotates its API host / persisted-query
  hashes. The provider hard-codes the current values; when they drift, the fix is
  a one-file JS update (the whole point of the hosted-provider model). Bundled now,
  moves to the hosted repo in P4.

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

## 7. Build phasing (order, not scope cuts)

| Phase | Deliverable |
|---|---|
| **A** | AllAnime provider + decode; Node decode tests + live integration test |
| **B** | `media_kit` player module (full features), driven by example data first |
| **C** | Wire real UI: `SourceRepository`, Home (search), Detail (episodes), open Player |
| **D** | Resume + autoplay-next + DRM-skip; on-device smoke — watch a real episode |

## Out of scope (this vertical)

- New per-host extractors (P2), the hosted providers repo + manifest v2 guard (P4).
- Library / watch-status / history beyond per-episode resume (P5).
- Downloads (P6), Supabase sync, notifications (P7).
- Dedicated frontend-design polish pass (separate follow-up).
- `go_router` / deep links / DRM playback / casting / PiP.
