# WATCH_APP Netflix-grade Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. The **frontend-design** skill drives visual quality in Tasks D–G. Steps use checkbox (`- [ ]`).

**Goal:** Turn WATCH_APP into a Netflix-grade streaming UI with real browse rows, Continue Watching, and a working Sub/Dub toggle — visually identical on iOS + Android.

**Architecture:** Re-tune the existing theme tokens (coral-red accent `#FF4D57`, drop Cupertino), add a verified `popular` query + sub/dub threading to the AllAnime provider, add a `WatchHistory` Hive store, build streaming widgets (`ContentRow`/`ContinueCard`/`BrandLoader`/`Badge`/`RowSkeleton`), then redesign Home (rows) and Detail (working dub) and retune the Player.

**Tech Stack:** Flutter, bundled Inter, `flutter_js` provider runtime, Hive, `cached_network_image`, `media_kit`.

**Spec:** `docs/superpowers/specs/2026-05-31-watch-app-netflix-redesign.md`. **Branch:** `feat/apple-ui`.

**Verification:** iOS simulator (id `833AF76B-36BF-461C-893D-630807CBE1B4`) is the iteration surface — UI is identical Flutter so it carries to Android; NO Android auto-install/test (user verifies on hardware). Each task: `flutter analyze` clean + existing tests green + (D–G) an iOS screenshot. Provider/store tasks add real tests.

---

## File structure
```
lib/core/theme/app_colors.dart            MODIFY  re-tune palette (coral accent)
lib/core/theme/app_text.dart              MODIFY  + overline style; bolder tracking
lib/core/ui/brand_loader.dart             NEW     shimmer loader (replaces Cupertino spinner)
lib/core/ui/content_row.dart              NEW     horizontal poster row + section header
lib/core/ui/continue_card.dart            NEW     16:9 resume card
lib/core/ui/badge.dart                    NEW     SUB/DUB/NEW pill
lib/core/ui/row_skeleton.dart             NEW     shimmer row placeholder
providers/allanime.js                     MODIFY  + popular(); thread category through detail/episodes
js_harness/allanime.test.mjs              MODIFY  + popular shape + dub-url tests
lib/core/models/media_item.dart           MODIFY  + subCount/dubCount
lib/core/models/media_detail.dart         MODIFY  + subCount/dubCount
lib/core/provider/base_provider.dart      MODIFY  popular(); category on detail/episodes
lib/core/provider/provider_manager.dart   MODIFY  implement above
lib/core/repository/source_repository.dart MODIFY popular/detail/episodes signatures
lib/core/playback/watch_history.dart      NEW     Hive Continue-Watching store
test/playback/watch_history_test.dart     NEW     unit test
lib/core/di/injector.dart                 MODIFY  register/init WatchHistory
lib/main.dart                             MODIFY  WatchHistory.init()
lib/features/home/home_screen.dart        MODIFY  rows layout
lib/features/home/search_screen.dart      NEW     extracted search (keeps current behavior)
lib/features/detail/detail_screen.dart    MODIFY  redesign + working dub
lib/features/player/player_screen.dart    MODIFY  BrandLoader + accept show context
lib/features/player/player_controller.dart MODIFY write WatchHistory on persist
```

---

## Task A: Re-tune theme + BrandLoader (drop Cupertino)

**Files:** modify `app_colors.dart`, `app_text.dart`; create `brand_loader.dart`.

- [ ] **Step 1:** In `lib/core/theme/app_colors.dart` update the values (keep the class name + member names so nothing else breaks; only values + 3 additions change):
```dart
import 'package:flutter/material.dart';

abstract class AppColors {
  static const bg = Color(0xFF0B0B0F);
  static const surface = Color(0xFF16161C);
  static const surface2 = Color(0xFF20212A);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFA7A7B2);
  static const textTertiary = Color(0xFF6E6E78);
  static const hairline = Color(0x14FFFFFF);
  static const accent = Color(0xFFFF4D57);          // coral-red signature
  static const accentSoft = Color(0x26FF4D57);       // accent @ ~15% for tints/chips

  /// Bottom-up scrim for art overlays (near-black → transparent).
  static const scrim = LinearGradient(
    begin: Alignment.bottomCenter, end: Alignment.topCenter,
    colors: [Color(0xF20B0B0F), Color(0x000B0B0F)], stops: [0.0, 0.65],
  );
  /// Top-down scrim for hero readability under the status bar.
  static const topScrim = LinearGradient(
    begin: Alignment.topCenter, end: Alignment.bottomCenter,
    colors: [Color(0x990B0B0F), Color(0x000B0B0F)], stops: [0.0, 0.5],
  );
}
```

- [ ] **Step 2:** In `lib/core/theme/app_text.dart` add an `overline` style and keep the rest:
```dart
  static const overline = TextStyle(fontFamily: _f, fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: AppColors.textSecondary);
```
(Leave `largeTitle/title/headline/body/caption/button` as-is.)

- [ ] **Step 3:** `lib/core/ui/brand_loader.dart` — the non-Apple loader: a slim rounded bar (height 3, width ~120, `surface2` track) with an accent gradient sweeping left→right on a single repeating `AnimationController` (1100ms), plus an optional label below in `AppText.body`. One controller, disposed in `dispose()`, wrapped in `RepaintBoundary`. Signature: `BrandLoader({String? label})`. Centered usage via a `BrandLoader` in a `Center`.
```dart
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class BrandLoader extends StatefulWidget {
  const BrandLoader({super.key, this.label});
  final String? label;
  @override
  State<BrandLoader> createState() => _BrandLoaderState();
}

class _BrandLoaderState extends State<BrandLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 120, height: 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Stack(children: [
              const ColoredBox(color: AppColors.surface2, child: SizedBox.expand()),
              AnimatedBuilder(
                animation: _c,
                builder: (context, _) => Align(
                  alignment: Alignment(-1.0 + 2.0 * _c.value, 0),
                  child: const FractionallySizedBox(
                    widthFactor: 0.4, heightFactor: 1,
                    child: DecoratedBox(decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [Color(0x00FF4D57), AppColors.accent, Color(0x00FF4D57)]))),
                  ),
                ),
              ),
            ]),
          ),
        ),
        if (widget.label != null) ...[
          const SizedBox(height: 14),
          Text(widget.label!, style: AppText.body),
        ],
      ]),
    );
  }
}
```

- [ ] **Step 4:** `flutter analyze` → No issues. `flutter test` → green. Commit `feat(ui): retune palette to coral-red + BrandLoader (drop Cupertino)`.

---

## Task B: Provider — `popular()` + sub/dub threading

**Files:** modify `providers/allanime.js`, `js_harness/allanime.test.mjs`. All queries verified live (see spec §live-API).

- [ ] **Step 1:** Extend `SHOW_GQL` to fetch English name + counts:
```js
var SHOW_GQL = 'query ($showId: String!) { show( _id: $showId ) { _id name englishName thumbnail description availableEpisodes availableEpisodesDetail }}';
```

- [ ] **Step 2:** Add the popular query + function (insert near `search`):
```js
var POPULAR_GQL = 'query($type:VaildPopularTypeEnumType!,$size:Int!,$dateRange:Int,$page:Int,$allowAdult:Boolean,$allowUnknown:Boolean){queryPopular(type:$type,size:$size,dateRange:$dateRange,page:$page,allowAdult:$allowAdult,allowUnknown:$allowUnknown){recommendations{anyCard{_id name englishName thumbnail availableEpisodes __typename}}}}';

function popular(opts) {
  opts = opts || {};
  var vars = { type: 'anime', size: opts.size || 26,
    dateRange: (opts.dateRange == null ? 7 : opts.dateRange),
    page: opts.page || 1, allowAdult: false, allowUnknown: false };
  return _post(POPULAR_GQL, vars).then(function (j) {
    var recs = (j && j.data && j.data.queryPopular && j.data.queryPopular.recommendations) || [];
    var out = [];
    for (var i = 0; i < recs.length; i++) {
      var c = recs[i] && recs[i].anyCard; if (!c || !c._id) continue;
      var ae = c.availableEpisodes || {};
      out.push({ id: c._id, title: c.name, englishTitle: c.englishName || null,
        cover: c.thumbnail || null, url: c._id, type: 'anime', sourceId: SOURCE_ID,
        subCount: ae.sub || 0, dubCount: ae.dub || 0 });
    }
    return out;
  });
}
```

- [ ] **Step 3:** Rewrite `getDetail` to be category-aware and carry counts (replace the existing `getDetail` + `_episodesFromDetail`):
```js
function getDetail(url, opts) {
  var showId = String(url);
  var cat = (opts && opts.category === 'dub') ? 'dub' : 'sub';
  return _post(SHOW_GQL, { showId: showId }).then(function (j) {
    var show = (j && j.data && j.data.show) || {};
    var aed = show.availableEpisodesDetail || {};
    var ae = show.availableEpisodes || {};
    var keys = (aed[cat] || []).slice().sort(function (a, b) { return parseFloat(a) - parseFloat(b); });
    var eps = [];
    for (var i = 0; i < keys.length; i++) {
      var n = keys[i];
      eps.push({ id: cat + ':' + n, title: 'Episode ' + n, number: parseFloat(n),
        url: 'allanime://' + showId + '/' + cat + '/' + n });
    }
    return { id: showId, title: show.name || showId, englishTitle: show.englishName || null,
      cover: show.thumbnail || null, url: showId, description: show.description || '',
      status: 'unknown', genres: [], studios: [], type: 'anime', sourceId: SOURCE_ID,
      episodes: eps, subCount: (ae.sub != null ? ae.sub : (aed.sub || []).length),
      dubCount: (ae.dub != null ? ae.dub : (aed.dub || []).length) };
  });
}

function getEpisodes(url, opts) { return getDetail(url, opts).then(function (d) { return d.episodes; }); }
```
(Delete the old `_episodesFromDetail`; `getVideoSources` already parses mode from the `/<cat>/` URL segment — no change needed.)

- [ ] **Step 4:** In `js_harness/allanime.test.mjs` add: (a) a unit test that `getDetail(id,{category:'dub'})` produces episode URLs containing `/dub/` and ids prefixed `dub:`; (b) a `RUN_LIVE`-gated test that `popular({dateRange:7})` returns a non-empty list of items each with `id/title/cover` and numeric `subCount`. Follow the existing harness patterns in that file. Run `node --test js_harness/allanime.test.mjs` (and `RUN_LIVE=1 node --test ...` once to confirm live) → pass.

- [ ] **Step 5:** Commit `feat(provider): allanime popular() + sub/dub-aware getDetail/getEpisodes`.

---

## Task C: Dart contract + models + repository + WatchHistory

**Files:** modify `base_provider.dart`, `provider_manager.dart`, `media_item.dart`, `media_detail.dart`, `source_repository.dart`; create `watch_history.dart` + its test; modify `injector.dart`, `main.dart`.

- [ ] **Step 1:** Add `subCount`/`dubCount` (nullable int, `@JsonKey` default null) to `MediaItem` and `MediaDetail` (add to constructor, fields, `props`, and the json). Then regenerate: `dart run build_runner build --delete-conflicting-outputs`. Confirm `*.g.dart` updated and `flutter analyze` clean.

- [ ] **Step 2:** `base_provider.dart` — update the interface:
```dart
Future<List<MediaItem>> popular({String category, int dateRange, int page});
Future<List<MediaItem>> search(String query, int page, {String category});
Future<MediaDetail> getDetail(String url, {String category});
Future<List<Episode>> getEpisodes(String url, {String category});
```
(Keep `getInfo`/`getVideoSources`.)

- [ ] **Step 3:** `provider_manager.dart` — implement on `JsProvider` (mirror the existing `_call` pattern):
```dart
@override
Future<List<MediaItem>> popular({String category = 'sub', int dateRange = 7, int page = 1}) async {
  final raw = await _call('popular', [{'category': category, 'dateRange': dateRange, 'page': page}]);
  final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  return list.map((m) => MediaItem.fromJson({...m, 'sourceId': sourceId})).toList();
}

@override
Future<MediaDetail> getDetail(String url, {String category = 'sub'}) async {
  final raw = await _call('getDetail', [url, {'category': category}]);
  final map = jsonDecode(raw) as Map<String, dynamic>;
  return MediaDetail.fromJson({...map, 'sourceId': sourceId});
}

@override
Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) async {
  final raw = await _call('getEpisodes', [url, {'category': category}]);
  final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
  return list.map(Episode.fromJson).toList();
}
```
(Update `search` to pass page through unchanged; it already accepts `category`.)

- [ ] **Step 4:** `source_repository.dart` — expose:
```dart
Future<List<MediaItem>> popular({String category = 'sub', int dateRange = 7, int page = 1}) =>
    _p.popular(category: category, dateRange: dateRange, page: page);
Future<List<MediaItem>> search(String query, {String category = 'sub'}) => _p.search(query, 1, category: category);
Future<MediaDetail> detail(String url, {String category = 'sub'}) => _p.getDetail(url, category: category);
Future<List<Episode>> episodes(String url, {String category = 'sub'}) => _p.getEpisodes(url, category: category);
```

- [ ] **Step 5:** `lib/core/playback/watch_history.dart` — new Hive store (box `watch_history`):
```dart
import 'package:hive/hive.dart';

class HistoryEntry {
  HistoryEntry({required this.sourceId, required this.showId, required this.showTitle,
    this.cover, this.coverHeaders, required this.showUrl, required this.category,
    required this.episodeId, required this.episodeNumber, required this.episodeUrl,
    required this.position, required this.duration, required this.updatedAt});
  final String sourceId, showId, showTitle, showUrl, category, episodeId, episodeUrl;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final double? episodeNumber;
  final Duration position, duration;
  final int updatedAt;
  bool get finished => duration.inMilliseconds > 0 &&
      position.inMilliseconds >= duration.inMilliseconds * 0.92;
  double get progress => duration.inMilliseconds == 0
      ? 0 : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
}

class WatchHistory {
  static const String boxName = 'watch_history';
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) { await Hive.openBox<Map>(boxName); }
  }
  Box<Map> get _box => Hive.box<Map>(boxName);
  String _key(String sourceId, String showId) => '$sourceId::$showId';

  Future<void> save(HistoryEntry e) async {
    await _box.put(_key(e.sourceId, e.showId), {
      'sourceId': e.sourceId, 'showId': e.showId, 'showTitle': e.showTitle,
      'cover': e.cover, 'coverHeaders': e.coverHeaders, 'showUrl': e.showUrl,
      'category': e.category, 'episodeId': e.episodeId, 'episodeNumber': e.episodeNumber,
      'episodeUrl': e.episodeUrl, 'positionMs': e.position.inMilliseconds,
      'durationMs': e.duration.inMilliseconds, 'updatedAt': e.updatedAt,
    });
  }

  HistoryEntry _fromMap(Map raw) {
    final m = Map<String, dynamic>.from(raw);
    return HistoryEntry(
      sourceId: m['sourceId'] as String, showId: m['showId'] as String,
      showTitle: m['showTitle'] as String? ?? '',
      cover: m['cover'] as String?,
      coverHeaders: (m['coverHeaders'] as Map?)?.map((k, v) => MapEntry('$k', '$v')),
      showUrl: m['showUrl'] as String? ?? '', category: m['category'] as String? ?? 'sub',
      episodeId: m['episodeId'] as String? ?? '',
      episodeNumber: (m['episodeNumber'] as num?)?.toDouble(),
      episodeUrl: m['episodeUrl'] as String? ?? '',
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
      updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// Newest-first, excluding finished episodes (the Continue Watching feed).
  List<HistoryEntry> recent({int limit = 20}) {
    final all = _box.values.map(_fromMap).where((e) => !e.finished).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return all.take(limit).toList();
  }
}
```

- [ ] **Step 6:** `test/playback/watch_history_test.dart` — open a temp Hive box (`Hive.init(tempDir)`), save three entries with different `updatedAt`, assert `recent()` is newest-first and that an entry with `position >= 92%` of duration is excluded. Run `flutter test test/playback/watch_history_test.dart` → pass.

- [ ] **Step 7:** Register in `injector.dart` (singleton `WatchHistory`) and call `await WatchHistory.init()` in `main.dart` next to `ResumeStore.init()`. `flutter analyze` clean.

- [ ] **Step 8:** Commit `feat(data): popular/category contract + counts + WatchHistory store`.

---

## Task D: Streaming shared widgets

**Files:** create `content_row.dart`, `continue_card.dart`, `badge.dart`, `row_skeleton.dart`. **frontend-design drives the visuals.** Reuse `PosterCard` (retune its radius to 12 + new tokens if needed).

- [ ] **Step 1: `badge.dart`** — `Badge({required String text, Color? color})`: a small pill, `accentSoft` fill (or `color`), `AppText.overline` in `accent` (or white), radius 6, tight padding. `const`-friendly.

- [ ] **Step 2: `content_row.dart`** — `ContentRow({required String title, String? overline, required Widget Function(BuildContext, int) itemBuilder, required int itemCount, double itemWidth = 124, double itemHeight = 210, VoidCallback? onSeeAll})`:
  - A header row: `title` in `AppText.headline` (+ optional `overline` label above in `AppText.overline`), optional "See All" (accent, `AppText.caption`) on the right; padding `EdgeInsets.fromLTRB(16,0,16,10)`.
  - A `SizedBox(height: itemHeight)` containing a horizontal `ListView.builder(scrollDirection: Axis.horizontal, padding: EdgeInsets.symmetric(horizontal: 16), cacheExtent: 600, itemCount, itemBuilder)`; each item is `SizedBox(width: itemWidth, ...)` with `RepaintBoundary`, separated by 12px. Edge-bleed (items run off the right edge).

- [ ] **Step 3: `continue_card.dart`** — `ContinueCard({required String title, String? imageUrl, Map<String,String>? headers, required double progress, String? subtitle, VoidCallback? onTap, double width = 260})`: a 16:9 `ClipRRect`(radius 12) with `CachedNetworkImage(memCacheWidth: (width*dpr))` + bottom `scrim`, a centered translucent play glyph (`Icons.play_arrow` in a 44px frosted circle), a bottom **accent progress bar** (height 3, `progress` fraction over `hairline`), and below the image the `title` (`AppText.body` white, 1 line) + `subtitle` (`AppText.caption`, e.g. "E7 • 12m left"). Press-scale + `RepaintBoundary`.

- [ ] **Step 4: `row_skeleton.dart`** — `RowSkeleton({double itemWidth=124, double itemHeight=210})`: a header-strip placeholder + a non-scrolling `Row` of ~5 `surface2` rounded rects (radius 12), one shared shimmer controller (reuse the shimmer approach in `states.dart`), disposed properly, `RepaintBoundary`.

- [ ] **Step 5:** `flutter analyze` → No issues; `flutter test` green. Commit `feat(ui): streaming widgets (ContentRow, ContinueCard, Badge, RowSkeleton)`.

---

## Task E: Home — rows layout

**Files:** modify `home_screen.dart`; create `search_screen.dart`. **frontend-design drives composition.**

- [ ] **Step 1:** Extract the current search UI into `lib/features/home/search_screen.dart` — a full screen with the large-title + rounded search field + results grid + Skeleton/Empty states (move the Task-C/Home work here verbatim, but `_repo.search(q)` now takes no positional page; call `_repo.search(q.trim())`). Tapping a result → `DetailScreen(item:)`. Keep the block-body `setState`.

- [ ] **Step 2:** Rebuild `home_screen.dart` as a `Scaffold` + `RefreshIndicator` + `CustomScrollView`:
  - A pinned/floating compact header: the "WATCH_APP" wordmark (`AppText.title`/`largeTitle`) + a search icon button → pushes `SearchScreen`.
  - `SliverList`/`SliverToBoxAdapter` sequence of rows, each independently loaded:
    - **Continue Watching**: read `sl<WatchHistory>().recent()`; if non-empty, a `ContentRow` of `ContinueCard` (tap → resume in player; see Task G for the resume entry-point). If empty, omit the row entirely.
    - **Trending Now** (`FutureBuilder(_repo.popular(dateRange: 1))`), **Popular This Month** (`dateRange: 30`), **All-Time** (`dateRange: 0`): each its own `FutureBuilder<List<MediaItem>>` → `RowSkeleton` while waiting, a `ContentRow` of `PosterCard` on data, and on error/empty **omit the row** (quiet). Cells tap → `DetailScreen(item:)`.
  - Add a staggered fade/slide-in entrance for rows (cheap; e.g. `TweenAnimationBuilder` opacity+translateY with per-row delay). Bottom padding.
  - Each row fetches once (cache the `Future` in `initState`/state, not in `build`, to avoid refetch on rebuild). `RefreshIndicator.onRefresh` re-creates the futures + re-reads history.

- [ ] **Step 3:** `flutter analyze` clean; `flutter test` green. iOS screenshot (Task H drives the real pass). Commit `feat(ui): Netflix-style Home with browse rows + Continue Watching`.

---

## Task F: Detail — redesign + working Sub/Dub

**Files:** modify `detail_screen.dart`. **frontend-design drives composition.**

- [ ] **Step 1:** Convert the screen to be **category-stateful**: hold `String _category = 'sub'` and `Future<MediaDetail> _detail`. `initState` → `_detail = _repo.detail(widget.item.url, category: _category)`. The Sub/Dub `SegmentedToggle` `onChanged` sets `_category` and re-assigns `_detail = _repo.detail(widget.item.url, category: _category)` inside `setState` (re-fetches the correct episode set). Disable/grey the **Dub** segment when the loaded detail's `dubCount == 0` (and force `sub`).

- [ ] **Step 2:** Rebuild the visual per the spec with the new tokens: hero `SliverAppBar` (cover + `topScrim`+`scrim`, no live blur, RepaintBoundary), large title + englishTitle + meta row (`{n} Episodes • {status} • {first genre}`), a white **PrimaryButton** Play/Continue (mode-aware resume via `WatchHistory`/`ResumeStore` — keep the "Continue when any mark exists" logic), the Sub/Dub `SegmentedToggle`, description (3 lines), then the episode `SliverList`. Each episode row: number • title, a **DUB `Badge`** when `_category=='dub'` and a **FILLER `Badge`** when `ep.filler`, a resume progress bar (accent) + Resume/✓ from `ResumeStore.get(widget.item.sourceId, ep.id)` (ids are now `sub:`/`dub:` prefixed — correct per mode). Loading → `BrandLoader`; error → `EmptyState`.

- [ ] **Step 3:** Opening an episode pushes the player **with show context** (Task G): `_openPlayer(eps, index)` now also passes `showTitle: detail.title, cover: detail.cover, coverHeaders: detail.coverHeaders, showUrl: widget.item.url, category: _category`.

- [ ] **Step 4:** `flutter analyze` clean; `flutter test` green; iOS screenshot in Task H. Commit `feat(ui): Detail redesign with working Sub/Dub + show-context handoff`.

---

## Task G: Player — BrandLoader + WatchHistory write

**Files:** modify `player_screen.dart`, `player_controller.dart`.

- [ ] **Step 1:** `player_controller.dart` — add optional show-context fields to the constructor (`showTitle`, `cover`, `coverHeaders`, `showUrl`, `category`, and a `WatchHistory? history`). In `_persist()` (already saves `ResumeStore`), ALSO write a `HistoryEntry` to `history` (when `history != null && _lastDur > 0`), using `currentEpisode` + the context (`updatedAt` from `DateTime.now().millisecondsSinceEpoch`). Keep all existing behavior.

- [ ] **Step 2:** `player_screen.dart` — add the matching constructor params (default null) and pass them to `PlayerController`. Replace the loading `_Centered(... CupertinoActivityIndicator/CircularProgressIndicator ...)` with `BrandLoader(label: 'Finding the best source…')`; retune the error state + frosted sheet to the new tokens/accent (the sheet logic stays exactly as in the current screen). Remove the `cupertino.dart` import.

- [ ] **Step 3:** Provide a resume entry-point for Continue Watching: a small helper (e.g. a static `PlayerScreen.fromHistory(HistoryEntry e, ...)` or a route built in Home) that opens the player at the history entry's show/episode. Simplest: from Home's `ContinueCard.onTap`, fetch `_repo.episodes(e.showUrl, category: e.category)`, find the index of `e.episodeId`, and push `PlayerScreen(... startIndex: idx, showContext...)`. Implement this in Home (Task E wiring) using the repository — document it where the `ContinueCard` is built.

- [ ] **Step 4:** `flutter analyze` clean; `flutter test` green. Commit `feat(ui): player BrandLoader + WatchHistory write + resume entry-point`.

---

## Task H: iOS on-device pass + refine

- [ ] **Step 1:** Hot-restart/relaunch on the booted iOS sim (`833AF76B-…`). Capture Home (rows), open a title → Detail, toggle Sub↔Dub (confirm the episode list changes), open an episode → Player loader + controls + quality sheet. Save screenshots.
- [ ] **Step 2:** Review each against the spec's look (coral accent, white Play, edge-bleed rows, no Cupertino spinner, working dub). Refine spacing/sizing/motion with frontend-design where it falls short; re-screenshot until it reads premium.
- [ ] **Step 3:** Record results. Note: the sim/emulator may lack CDN network (playback errors are environmental); judge layout/visuals, and the user validates playback on a physical device.

---

## Self-review
**Spec coverage:** §1 palette/type/loader → A. §2 widgets → D (+ reuse PosterCard). §3 data (popular/dub/WatchHistory) → B+C. §4 screens → E (Home), F (Detail+dub), G (Player). §5 Android perf → enforced in D/E/F (blur only on sheet, memCacheWidth, lazy rows, single shimmer controller). §6 testing → B/C tests + H iOS pass. §7 phasing → A–H. ✓
**Type consistency:** `AppColors`/`AppText.overline`/`BrandLoader` (A) used in D–G. `popular`/`getDetail(category:)`/`getEpisodes(category:)` consistent across base_provider→provider_manager→source_repository (B/C). Episode id scheme `cat:n` + URL `/cat/n` consistent between provider (B) and resume reads (F). `HistoryEntry`/`WatchHistory.recent()` (C) used by Home (E) + Player (G). `subCount`/`dubCount` added in models (C), produced by provider (B), consumed by Detail (F). ✓
**Placeholder scan:** deterministic layers (A theme/loader, B provider, C models/contract/store) carry full code; D–G are concrete composition specs (every widget/param/data-call named) refined visually on-device — deliberate, no "TBD".

## Risks
- Changing `Episode.id` to `cat:n` orphans any existing resume marks (dev-only data) — acceptable, no migration.
- `popular` is plain POST GraphQL (no persisted hash) — verified working; if AllAnime later requires a hash, the row fetch fails gracefully (row omitted), Home still works.
- iOS sim navigation for screenshots may need a tap mechanism (idb/AppleScript) — Home needs none; for Detail/Player I'll drive taps or, if blocked, capture via the identical Android render as a fallback for layout only.
