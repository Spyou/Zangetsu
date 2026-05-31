# WATCH_APP — Netflix-grade Redesign + Browse + Functional Dub — Design Spec

**Date:** 2026-05-31
**Status:** Proposed (pending user review)
**Supersedes:** the screen sections of `2026-05-30-watch-app-apple-ui-design.md`. Keeps that work's
foundation (bundled Inter, theme-token architecture, shared widget kit, Android-perf rules) but
**re-tunes the palette, drops the overtly "Apple" tells, and adds real content + functional dub.**
**Branch:** `feat/apple-ui` (unmerged — this continues on it).

## Why (user feedback, 2026-05-31)
Verbatim drivers: *"more perfect like netflix"*, *"dont want to show apple type thing like loading
etc"*, *"card design i like it"*, *"why not have home screen design also"*, *"detail screen is not
good"*, *"i tap dub its literally not show dub one"*, *"according to you design … and colour also"*,
*"same design ios and android"*, *"test i[n] ios … then i will use physical device"*.

Decisions locked (via questions): **real browse rows** (provider gets Popular/Trending) + **Continue
Watching**; **make Sub/Dub functional now**. Aesthetic + palette delegated to me.

## Live-API verification (done before this spec)
- `queryPopular(type:"anime", size, dateRange, page)` — plain POST GraphQL (no persisted hash).
  Returns `recommendations[].anyCard { _id, name, englishName, thumbnail, availableEpisodes{sub,dub,raw} }`.
  `dateRange` 1 / 30 / 0 give **distinct** rows (today / month / all-time). Verified non-empty.
- `show.availableEpisodesDetail` returns **separate `sub` and `dub` string-number arrays** — dub episodes
  are individually addressable. Confirmed (Wistoria S2 → 9 sub, 6 dub).
- Root cause of the dub bug: `getDetail` hardcodes the episode URL `allanime://<id>/sub/<n>`, so
  `getVideoSources` always parses mode `sub`. Fix = thread the chosen mode into the URL + episode set.

## 1. Visual identity (the "design" decision)
**Direction:** premium cinematic streaming (Netflix/Crunchyroll energy), dark, art-forward, with
confident motion. Distinctive — not generic Material, not overtly Apple.

- **Color (`app_colors.dart`, re-tuned):**
  - `bg` `#0B0B0F` (cool near-black), `surface` `#16161C`, `surface2` `#20212A`, `surfaceGlass` (translucent for overlays).
  - text `#FFFFFF` / secondary `#A7A7B2` / tertiary `#6E6E78`; hairline `#FFFFFF14`.
  - **`accent` = coral-red `#FF4D57`** (brand / active / progress / badges). **Primary action button = white** (black label) — the premium streaming move. `accentSoft` (accent @ ~15%) for chips/tints.
  - Keep the bottom-up `scrim` gradient; add a `topScrim` (top→transparent) for hero readability under status bar.
- **Type:** keep bundled **Inter** (cross-platform parity — a locked requirement; user didn't object).
  Push character through weight + tracking: large titles 700/-0.5, section headers 700/17, a new
  `overline` (12/600, +0.8 tracking, uppercase) for row labels and badges. (A distinctive display
  font is a possible later flourish; out of scope now to keep the asset surface stable.)
- **Shape/space:** card radius 12, sheet radius 22, chips 8; 4-pt spacing; screen padding 16 (rows
  bleed to the edge for the "content continues offscreen" streaming feel).
- **Motion:** staggered fade/slide-in on row load (cheap, `AnimatedOpacity`/`Transform`), poster
  press-scale (kept), accent underline slide on the segmented toggle. No continuous repaints.
- **No Cupertino tells:** remove `CupertinoActivityIndicator`. New **`BrandLoader`** = a slim
  accent shimmer bar / pulsing logotype used for all loading states.

## 2. Shared widgets (`lib/core/ui/`) — extend the kit
Keep `PosterCard` (liked) — retune radius/scrim to new tokens. Keep `FrostedSurface`, `PrimaryButton`,
`SegmentedToggle`, `EmptyState`. **Add:**
- **`ContentRow`** — a horizontal `ListView.builder` (`scrollDirection: horizontal`, `cacheExtent`,
  edge-bleed padding) with a `SectionHeader` (overline label + optional "See all"); cells are
  `PosterCard` sized to a fixed poster width; lazy + `RepaintBoundary` per cell; sized-decode preserved.
- **`ContinueCard`** — a wider 16:9 landscape card for the Continue-Watching row: thumbnail + bottom
  accent progress bar + title + "S?E?" label + a centered play glyph.
- **`BrandLoader`** — the non-Apple loader (shimmer bar). Replaces spinners app-wide.
- **`RowSkeleton`** — shimmer placeholder shaped like a `ContentRow` (reuses the single-controller shimmer).
- **`Badge`** — small accent pill ("NEW", "DUB", "SUB") in `overline` style.

## 3. Data layer
- **Provider (`providers/allanime.js`):**
  - Add **`popular(opts)`** → uses `queryPopular` with `opts.dateRange` (default 7), `opts.page`,
    `opts.category` (translationType), `size` 26. Maps `anyCard` → the same item shape as `search`
    (id, title, englishTitle, cover, url=`_id`, type, sourceId) and includes `availableEpisodes`
    (sub/dub counts) so the UI can show DUB availability.
  - **Thread `category` (sub/dub) through `getDetail`/`getEpisodes`:** accept `opts.category`; build
    episodes from the matching `availableEpisodesDetail[category]` array only; episode URL becomes
    `allanime://<showId>/<category>/<number>`. Also return `availableEpisodes` (sub/dub counts) on the
    detail so the Detail screen can disable the Dub segment when `dub == 0`.
  - `getVideoSources` already parses mode from the URL → now correctly resolves dub when the URL says `/dub/`.
- **Dart contract:** add `JsProvider.popular(...)` + `ProviderManager` plumbing; extend
  `getDetail`/`getEpisodes` to pass `category`. Models: add optional `englishTitle` already exists;
  add `subCount`/`dubCount` (ints) to `MediaItem`/`MediaDetail` (nullable, default null) — or carry a
  small `EpisodeCounts` value. `SourceRepository`: `popular({category, dateRange, page})`,
  `detail(url, {category})`, `episodes(url, {category})`.
- **Watch history (`lib/core/playback/watch_history.dart`, new Hive box):** the current `ResumeStore`
  only keeps position/duration keyed by `sourceId::episodeId` — not enough to render a card or
  deep-link back. Add a `WatchHistory` store keyed by `sourceId::showId` holding `{ showTitle, cover,
  coverHeaders, showUrl, category, episodeId, episodeNumber, episodeUrl, positionMs, durationMs,
  updatedAt }`. Written whenever the player persists progress (the player gains a small "show context"
  param: title/cover/coverHeaders/showUrl/category). `recent()` returns entries newest-first, skipping
  finished ones → powers the Continue Watching row + tapping resumes directly into the player.

## 4. Screens
- **Home** (`features/home`): a vertical `CustomScrollView` of rows:
  1. A compact brand header ("WATCH_APP" wordmark) + a tappable search affordance (opens a search
     view/route; search keeps current behavior + the new grid styling).
  2. **Continue Watching** `ContentRow` of `ContinueCard` (only if history non-empty) — tap resumes.
  3. **Trending Now** (`popular dateRange:1`), **Popular This Month** (`dateRange:30`), **All-Time**
     (`dateRange:0`) `ContentRow`s of `PosterCard`. Each loads independently (its own FutureBuilder +
     `RowSkeleton`), so one slow/failed row never blocks the others; failed row → quiet removal/empty.
  - Staggered entrance; pull-to-refresh re-fetches rows.
- **Detail** (`features/detail`): redesigned. Hero backdrop (cover + dual scrim, no live blur),
  title/English title/meta (year-free; episodes • status • first genre), **white Play / Continue**
  button (resume logic kept, now mode-aware), a **functional `SegmentedToggle` Sub/Dub** — switching
  re-fetches `episodes(url, category)` and rebuilds the list (Dub segment disabled + greyed when
  `dubCount == 0`); a clean episode list (number • title, DUB/FILLER badges, resume progress bar +
  Resume/✓ affordance). Opening an episode passes the show context to the player for history.
- **Player** (`features/player`): unchanged behavior; swap the loader to `BrandLoader`
  ("Finding the best source…"), keep the frosted quality/source sheet (now with new accent), accept
  the show-context param and persist `WatchHistory` on save. Sheet/error restyled to new tokens.

## 5. Android performance (unchanged rules — still enforced)
`BackdropFilter` blur ONLY on static overlays (the quality sheet); rows/hero use gradient scrims.
Posters decode at cell size (`memCacheWidth`). `const`/builders/`cacheExtent`/`RepaintBoundary`.
Horizontal rows are lazy. One shimmer controller per skeleton.

## 6. Testing / iteration
- **iOS simulator is the iteration surface** (UI is identical Flutter → carries to Android). I capture
  Home/Detail/Player screenshots there and refine. **No auto Android install/test loop.** The user
  validates on a **physical device**.
- New provider methods get Node-harness tests (`popular` shape, dub-URL construction) + live-gated
  (`RUN_LIVE=1`) checks. `flutter analyze` clean; existing Dart/JS suites stay green.
- `WatchHistory` gets a Dart unit test (save → recent ordering → finished filtering).

## 7. Phasing (one plan)
A: re-tune theme tokens + `BrandLoader` (drop Cupertino) → B: provider `popular` + dub threading
(+ Node tests, live-verified) → C: Dart contract/repository/models + `WatchHistory` → D: shared
widgets (`ContentRow`, `ContinueCard`, `Badge`, `RowSkeleton`) → E: Home with rows → F: Detail redesign
+ working Sub/Dub → G: Player loader/sheet retune + history write → H: iOS screenshots + refine.
The **frontend-design** skill drives visual quality in D–G.

## Out of scope
Light theme; a second/display font; new tabs (Library/Downloads); hosted providers; megacloud/HiAnime.
The emulator's missing CDN network (the "no source" error) is environmental — not addressed here.
