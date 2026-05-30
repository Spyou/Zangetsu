# WATCH_APP — Fast Source Resolution + Resolution Picker — Design Spec

**Date:** 2026-05-30
**Status:** Approved (design); pending implementation plan
**Builds on:** 2A (AllAnime provider), 2B (media_kit player), P2 (extractors) — all on `main`.

## Summary

Two related improvements to the watch experience:

1. **Fast source resolution** — kill the ~20s "Resolving sources…" wait. Today
   `getVideoSources` waits for *every* source job (via `Promise.all`); one dead
   AllAnime `clock` backend hits the 20s Dio receive-timeout and stalls the whole
   call. Fix: a **per-request fetch timeout** (so a dead backend fails fast) plus a
   **soft deadline** that returns whatever resolved within ~5s and drops stragglers.

2. **Explicit resolution selection (1080p/720p/…)** — today the primary AllAnime
   stream is an HLS *master* playlist surfaced as a single `auto` entry, so the
   player's picker has no per-resolution choices. Fix: **player-side lazy expansion**
   — when an HLS master is playing, parse it into its variant resolutions and offer
   them (plus `Auto`) in the picker; selecting one plays that exact variant.

### Decisions locked during brainstorming

| Topic | Decision |
|---|---|
| Quality selection | **Player-side lazy HLS-master expansion** (don't slow resolution; parse the master after playback starts) |
| Latency | **Bound + start fast**: per-request `timeoutMs` (~8s) + soft-deadline (~5s) return-what's-ready in `getVideoSources` |

## 1. Runtime primitives: per-request fetch timeout + `setTimeout` bridge

**1a. Per-request fetch timeout** — the JS `fetch` bridge gains an optional
`opts.timeoutMs`. The Dart `_onFetch` applies it as a per-request Dio
`Options(receiveTimeout:, sendTimeout:)` override (Dio default when absent). This
is the **reliable floor**: a dead backend fails in ≤`timeoutMs`, independent of any
timer. The Node harness mirror ignores it (real `fetch` has no knob; tests stub).
- `js_bootstrap.dart` `__fetch`: include `timeoutMs` in the payload.
- `provider_manager.dart` `_onFetch`: if `payload['timeoutMs']` is a positive int,
  set `receiveTimeout`/`sendTimeout` to that duration.

**1b. `setTimeout`/`clearTimeout` bridge** — QuickJS (flutter_js) does **not**
reliably provide `setTimeout`, which the §2 soft-deadline needs. Add a Dart-backed
timer bridge, mirroring the `fetch`/`crypto` bridges, and define it **guarded** so a
host-provided timer (if any) is preserved:
- `js_bootstrap.dart` (in `kJsBootstrap`): `if (typeof setTimeout !== 'function')`
  define `globalThis.setTimeout = function(fn, ms){ var id=__nextTimerId(); __timers[id]=fn; sendMessage('timer', JSON.stringify({id:id, ms: ms||0})); return id; }`
  and `globalThis.clearTimeout = function(id){ delete __timers[id]; }`, plus a
  `globalThis.__fireTimer(id)` that pops and invokes the stored callback.
- `provider_manager.dart`: `onMessage('timer', _onTimer)` → `Future.delayed(Duration(ms), () => _runtime.evaluate('__fireTimer(<id>)'))`. (Only fires; `clearTimeout` just drops the JS-side callback so a fired-but-cleared id is a no-op.)
- The Node harness has native `setTimeout`, so its mirror is a no-op (nothing to add).

## 2. Soft-deadline resolution (`providers/allanime.js`)

`getVideoSources` currently builds `jobs[]` and does `Promise.all(jobs)`. Change to:

- Each resolution fetch (clock + embed `extractVideo`) passes `timeoutMs: 8000`
  through to `fetch`/`extractVideo` so a single dead host fails in ≤8s, not 20s.
- Replace `Promise.all(jobs)` with a **soft-deadline collector**: jobs run
  concurrently; each appends its result (a `[VideoSource]`) to a shared array on
  settle; the call resolves at **whichever comes first**: all jobs settled, or a
  **~5000ms deadline**. Sources not yet resolved at the deadline are dropped.
  Implemented with `Promise.race([allSettled, deadline(5000)])` where the deadline
  resolves to the collected-so-far results, using the `setTimeout` bridge from §1b
  (native in the Node harness). If `setTimeout` somehow resolves to a no-op, the
  per-fetch `timeoutMs` (§1a) still bounds the call — so latency is fixed either way.
- The instant direct sources (e.g. `Yt-mp4`) and the fast wixmp `Default` clock land
  well within the deadline; the dead backend is dropped. If nothing resolved, throw
  `'AllAnime: no playable sources'` as today.
- The episode-`url` shape, decrypt, hex-decode, and embed→`extractVideo` routing are
  otherwise unchanged.

## 3. Player-side HLS-master expansion (quality picker)

### `lib/core/playback/hls.dart` (new)
- `class HlsVariant { final String quality; final String url; }`
- `List<HlsVariant> parseHlsMaster(String playlist, String masterUrl)` — **pure**:
  scans `#EXT-X-STREAM-INF:` lines, reads `RESOLUTION=WxH` (quality = `'<H>p'`;
  falls back to a `BANDWIDTH`-derived label when no RESOLUTION), pairs each with the
  following URI line, resolves relative URIs against `masterUrl`'s directory, and
  returns variants sorted high→low. Returns `[]` if not a master (no variants).
- `Future<List<HlsVariant>> fetchHlsVariants(String masterUrl, Map<String,String>? headers, Dio dio)`
  — GETs the master (plain) and calls `parseHlsMaster`.

### `lib/features/player/player_controller.dart`
- Add `List<HlsVariant> qualities = []` and `HlsVariant? activeQuality` (null = Auto/master).
- After `_open(source)` succeeds for a `container == hls` source: in the background
  (does **not** block playback start), call `fetchHlsVariants(source.url, source.headers, dio)`;
  on success set `qualities` (the variants) and `notifyListeners()`. Non-HLS or
  parse-empty → `qualities = []`.
- `selectQuality(HlsVariant? v)`: `v == null` → re-open the master (`active.url`) at
  the current position (Auto/adaptive); else open `v.url` at the current position.
  Uses the existing generation-guarded `_open(..., seekTo: _lastPos)`. Sets
  `activeQuality`. Switching quality must **not** drop the resume position.
- `Dio` is injected into `PlayerController` (from `sl<Dio>()`) for the master fetch;
  pass it via the constructor (PlayerScreen already builds the controller).

### `lib/features/player/player_screen.dart`
- The quality picker (the `high_quality` icon → bottom sheet) gains a **Quality**
  section when `qualities` is non-empty: `Auto` (checked when `activeQuality == null`)
  + each variant (`1080p`, `720p`, …), tapping → `selectQuality(v)`. The existing
  sub/dub + non-HLS-source rows remain (they switch `VideoSource` via `switchSource`).
- The status line shows the active quality (`activeQuality?.quality ?? 'Auto'`).

## 4. Data flow

```
Detail → PlayerController.openEpisode
  → SourceRepository.sources()  [bounded ~5s, returns fast sources]
  → pickDefault → _open(best)   [playback starts]
  → if best.container == hls: fetchHlsVariants(best.url) in background
       → qualities = [1080p, 720p, …]; notifyListeners (picker updates)
User taps 720p → selectQuality(v) → _open(v.url, seekTo: lastPos)
```

## 5. Testing

- **JS (deterministic):** stub `globalThis.__fetch` so one source resolves instantly
  and one "hangs" (never resolves); assert `getVideoSources` returns the fast source
  within the deadline and does **not** wait on the hung one. Plus: a `timeoutMs` is
  present in the fetch payload for resolution fetches.
- **Dart (TDD, pure):** `parseHlsMaster` on a sample multi-variant master → ordered
  `[1080p,720p,480p]` with correctly-resolved (relative→absolute) URLs; non-master
  input → `[]`.
- **Player logic:** quality-list set on HLS open; `selectQuality` opens the variant
  URL at the saved position (verified by reading state; full playback is on-device).
- **On-device smoke:** episode starts noticeably faster (no ~20s spinner); the
  picker lists `Auto/1080p/720p/…`; selecting a resolution visibly changes quality
  and resumes at the same spot. `flutter analyze` + existing tests stay green.

## 6. Build phasing (one plan)

A: runtime primitives — per-request fetch `timeoutMs` + `setTimeout`/`clearTimeout`
bridge (§1) → B: soft-deadline `getVideoSources` (§2) → C: `hls.dart`
`parseHlsMaster` (TDD) → D: `PlayerController` quality list + variant switching +
Dio injection → E: `player_screen` quality section → F: on-device smoke.

## Out of scope

- True source-by-source streaming (incremental delivery before the deadline) — the
  soft-deadline already removes the stall; full streaming is a larger contract change.
- Per-quality selection for non-HLS hosts that only expose one file (mp4upload,
  direct mp4) — they stay single-entry; okru already returns labeled mp4 variants.
- Bitrate/auto-quality preferences, remembering quality across episodes/launches.
