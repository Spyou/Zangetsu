# WATCH_APP Plan 2B — media_kit player + Search/Detail/Player UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the real AllAnime stream URLs (Plan 2A) into a watchable app — Search → Detail/Episodes → a full-featured `media_kit` player — ending with watching a real episode end-to-end on-device.

**Architecture:** A thin `SourceRepository` wraps the P1 `ProviderManager`. Pure-logic helpers (source grouping/quality sort, resume positions) are unit-tested headlessly. The `media_kit` player module wraps `Player`/`VideoController` with sub/dub + quality switching, soft subtitles, resume, autoplay-next, and try-next-source-on-error (covers DRM/dead sources). Minimal `Navigator`-based screens (Home → Detail → Player) replace the dev slice.

**Tech Stack:** `media_kit`, `media_kit_video`, `media_kit_libs_video`; Flutter `Navigator`; Hive (resume); the existing P0–2A runtime/models. iOS uses a CocoaPods pod (working since the env fix).

**Scope note:** Plan 2B of the playback vertical (spec: `docs/superpowers/specs/2026-05-30-watch-app-playback-vertical-design.md` §3–§5, §7 Plan 2B). Depends on 2A (merged to master). Most player/UI tasks are verified by an on-device smoke (media_kit + Flutter widgets can't run in headless `flutter test`); the pure-logic tasks are TDD'd.

**On-device learning from 2A (folded in):** `getVideoSources` can take ~20s (a dead AllAnime `clock` backend has to time out). So the Detail→Player transition MUST show a "loading sources" state, and the player tries sources in order, advancing past any that fail to start.

---

## File structure (this plan)

```
pubspec.yaml                                      # MODIFY: + media_kit deps
ios/Runner/Info.plist                             # MODIFY: ATS exception for arbitrary media loads
lib/main.dart                                     # MODIFY: MediaKit.ensureInitialized + launch HomeScreen
lib/core/
  repository/source_repository.dart               # NEW: search/detail/episodes/sources over ProviderManager
  playback/resume_store.dart                       # NEW: Hive-backed resume positions
  playback/source_selection.dart                   # NEW: pure helpers — group/sort/pick VideoSources
lib/features/
  home/home_screen.dart                            # NEW: search + results grid
  detail/detail_screen.dart                        # NEW: poster + sub/dub toggle + episode list
  player/player_controller.dart                    # NEW: Player lifecycle, switch, resume, autoplay, try-next
  player/player_screen.dart                        # NEW: Video widget + controls + pickers + loading state
test/playback/source_selection_test.dart           # NEW
test/playback/resume_store_test.dart               # NEW
```

---

## Task 1: media_kit dependencies + init + iOS ATS

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/main.dart`
- Modify: `ios/Runner/Info.plist`

- [ ] **Step 1: Add deps to `pubspec.yaml`** (under `dependencies:`)

```yaml
  # Video playback (libmpv-based). _libs_video bundles the native libs (iOS pod).
  media_kit: ^1.1.11
  media_kit_video: ^1.2.5
  media_kit_libs_video: ^1.0.5
```
Run: `cd "/Users/krishnavishwakarma/Programming Playground/watch_app" && flutter pub get`
Expected: `Got dependencies!`. If a version cannot resolve, pick the nearest resolvable and report it.

- [ ] **Step 2: Initialize MediaKit in `lib/main.dart`**

Add the import:
```dart
import 'package:media_kit/media_kit.dart';
```
In `main()`, after `WidgetsFlutterBinding.ensureInitialized();` and before `await initDependencies();`, add:
```dart
  MediaKit.ensureInitialized();
```

- [ ] **Step 3: Add an ATS exception in `ios/Runner/Info.plist`**

Inside the top-level `<dict>`, add (so non-HTTPS embed streams can play):
```xml
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
```

- [ ] **Step 4: Install pods + verify build**

Run: `cd ios && env -u GEM_HOME -u GEM_PATH /opt/homebrew/bin/pod install && cd ..`
Expected: `Pod installation complete!` (media_kit pods added).
Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock lib/main.dart ios/Runner/Info.plist ios/Podfile.lock ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(2b): add media_kit deps + init + iOS ATS exception"
```

---

## Task 2: Source selection helpers (`source_selection.dart`) — TDD

Pure functions over `VideoSource` lists — fully headless-testable.

**Files:**
- Create: `lib/core/playback/source_selection.dart`
- Test: `test/playback/source_selection_test.dart`

- [ ] **Step 1: Write the failing test**

`test/playback/source_selection_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/source_selection.dart';

VideoSource _s(String q, AudioKind k) =>
    VideoSource(url: 'https://x/$q', quality: q, container: SourceContainer.hls, kind: k);

void main() {
  test('sortByQuality orders high→low, unknown last', () {
    final out = sortByQuality([_s('480p', AudioKind.sub), _s('1080p', AudioKind.sub),
      _s('', AudioKind.sub), _s('720p', AudioKind.sub)]);
    expect(out.map((s) => s.quality).toList(), ['1080p', '720p', '480p', '']);
  });

  test('availableKinds lists distinct kinds present', () {
    final kinds = availableKinds([_s('720p', AudioKind.sub), _s('720p', AudioKind.dub),
      _s('480p', AudioKind.sub)]);
    expect(kinds.contains(AudioKind.sub), true);
    expect(kinds.contains(AudioKind.dub), true);
    expect(kinds.length, 2);
  });

  test('pickDefault prefers requested kind at highest quality', () {
    final all = [_s('480p', AudioKind.sub), _s('1080p', AudioKind.dub), _s('1080p', AudioKind.sub)];
    final picked = pickDefault(all, prefer: AudioKind.sub);
    expect(picked!.kind, AudioKind.sub);
    expect(picked.quality, '1080p');
  });

  test('pickDefault falls back to any kind when preferred absent', () {
    final all = [_s('720p', AudioKind.dub)];
    expect(pickDefault(all, prefer: AudioKind.sub)!.kind, AudioKind.dub);
  });

  test('sourcesForKind filters', () {
    final all = [_s('720p', AudioKind.sub), _s('720p', AudioKind.dub)];
    expect(sourcesForKind(all, AudioKind.dub).single.kind, AudioKind.dub);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/playback/source_selection_test.dart`
Expected: FAIL — URI doesn't exist.

- [ ] **Step 3: Write `lib/core/playback/source_selection.dart`**

```dart
import '../models/video_source.dart';

/// Parses a quality label like `'1080p'` into a comparable int (height in px).
/// Unknown/empty → -1 so it sorts last.
int qualityRank(String? quality) {
  if (quality == null) return -1;
  final m = RegExp(r'(\d{3,4})').firstMatch(quality);
  if (m == null) return -1;
  return int.tryParse(m.group(1)!) ?? -1;
}

/// Returns [sources] sorted by quality high→low; unknown qualities last.
/// Stable for equal ranks (preserves input order).
List<VideoSource> sortByQuality(List<VideoSource> sources) {
  final indexed = sources.asMap().entries.toList();
  indexed.sort((a, b) {
    final r = qualityRank(b.value.quality).compareTo(qualityRank(a.value.quality));
    return r != 0 ? r : a.key.compareTo(b.key);
  });
  return indexed.map((e) => e.value).toList();
}

/// Distinct [AudioKind]s present in [sources], in first-seen order.
List<AudioKind> availableKinds(List<VideoSource> sources) {
  final seen = <AudioKind>[];
  for (final s in sources) {
    if (!seen.contains(s.kind)) seen.add(s.kind);
  }
  return seen;
}

/// Only the sources matching [kind].
List<VideoSource> sourcesForKind(List<VideoSource> sources, AudioKind kind) =>
    sources.where((s) => s.kind == kind).toList();

/// Best default source: highest quality of [prefer]; if none of that kind,
/// highest quality overall. Null only when [sources] is empty.
VideoSource? pickDefault(List<VideoSource> sources, {AudioKind prefer = AudioKind.sub}) {
  if (sources.isEmpty) return null;
  final preferred = sortByQuality(sourcesForKind(sources, prefer));
  if (preferred.isNotEmpty) return preferred.first;
  return sortByQuality(sources).first;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/playback/source_selection_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/core/playback/source_selection.dart test/playback/source_selection_test.dart
git commit -m "feat(2b): source selection helpers (quality sort, sub/dub grouping, default pick)"
```

---

## Task 3: Resume store (`resume_store.dart`) — TDD

Hive-backed per-episode playback position. Headless-testable with a temp Hive dir.

**Files:**
- Create: `lib/core/playback/resume_store.dart`
- Test: `test/playback/resume_store_test.dart`

- [ ] **Step 1: Write the failing test**

`test/playback/resume_store_test.dart`:
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/resume_store.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('resume_test');
    Hive.init(tmp.path);
    await ResumeStore.init();
  });
  tearDown(() async {
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  test('save then get round-trips a position', () async {
    final store = ResumeStore();
    await store.save('allanime', 'ep-1', const Duration(seconds: 90), const Duration(minutes: 24));
    final mark = store.get('allanime', 'ep-1');
    expect(mark, isNotNull);
    expect(mark!.position.inSeconds, 90);
    expect(mark.duration.inMinutes, 24);
    expect(mark.finished, false);
  });

  test('get returns null for unknown episode', () {
    expect(ResumeStore().get('allanime', 'nope'), isNull);
  });

  test('finished is true when near the end (>92%)', () async {
    final store = ResumeStore();
    await store.save('allanime', 'ep-2', const Duration(minutes: 23, seconds: 30),
        const Duration(minutes: 24));
    expect(store.get('allanime', 'ep-2')!.finished, true);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/playback/resume_store_test.dart`
Expected: FAIL — URI doesn't exist.

- [ ] **Step 3: Write `lib/core/playback/resume_store.dart`**

```dart
import 'package:hive/hive.dart';

/// A saved playback position for one episode.
class ResumeMark {
  ResumeMark({required this.position, required this.duration});
  final Duration position;
  final Duration duration;

  /// Treat as watched when within the last ~8% of the runtime.
  bool get finished =>
      duration.inMilliseconds > 0 &&
      position.inMilliseconds >= duration.inMilliseconds * 0.92;
}

/// Hive-backed per-(sourceId, episodeId) resume positions.
class ResumeStore {
  static const String boxName = 'resume_positions';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  String _key(String sourceId, String episodeId) => '$sourceId::$episodeId';

  Future<void> save(
      String sourceId, String episodeId, Duration position, Duration duration) async {
    await _box.put(_key(sourceId, episodeId), {
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
    });
  }

  ResumeMark? get(String sourceId, String episodeId) {
    final raw = _box.get(_key(sourceId, episodeId));
    if (raw == null) return null;
    final m = Map<String, dynamic>.from(raw);
    return ResumeMark(
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
    );
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/playback/resume_store_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Register the box at startup.** In `lib/core/di/injector.dart`, after `await ProviderDownloader.init();`, add:
```dart
  await ResumeStore.init();
```
And add the import at the top:
```dart
import '../playback/resume_store.dart';
```
Run: `flutter analyze` → `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add lib/core/playback/resume_store.dart test/playback/resume_store_test.dart lib/core/di/injector.dart
git commit -m "feat(2b): Hive-backed resume positions (ResumeStore)"
```

---

## Task 4: SourceRepository

Thin async wrapper over `ProviderManager` so the UI doesn't touch the runtime directly.

**Files:**
- Create: `lib/core/repository/source_repository.dart`

- [ ] **Step 1: Create the file**

```dart
import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/video_source.dart';
import '../provider/provider_manager.dart';

/// Facade over the active provider runtime for the UI layer. For 2B it targets
/// the bundled AllAnime provider; later phases let the user pick the source.
class SourceRepository {
  SourceRepository({required ProviderManager manager, this.sourceId = 'allanime'})
      : _manager = manager;

  final ProviderManager _manager;
  final String sourceId;

  JsProvider get _p {
    final p = _manager.get(sourceId);
    if (p == null) throw StateError('Provider not loaded: $sourceId');
    return p;
  }

  Future<List<MediaItem>> search(String query, {String category = 'sub'}) =>
      _p.search(query, 1, category: category);

  Future<MediaDetail> detail(String url) => _p.getDetail(url);

  Future<List<Episode>> episodes(String url) => _p.getEpisodes(url);

  Future<List<VideoSource>> sources(String episodeUrl) =>
      _p.getVideoSources(episodeUrl);
}
```

- [ ] **Step 2: Register it in `lib/core/di/injector.dart`**

After the `manager.load(sourceId: 'allanime', ...)` block, add:
```dart
  sl.registerSingleton<SourceRepository>(SourceRepository(manager: manager));
```
Add the import:
```dart
import '../repository/source_repository.dart';
```

- [ ] **Step 3: Verify**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add lib/core/repository/source_repository.dart lib/core/di/injector.dart
git commit -m "feat(2b): SourceRepository facade over the provider runtime"
```

---

## Task 5: PlayerController (media_kit lifecycle + switching + resume + autoplay + try-next)

**Files:**
- Create: `lib/features/player/player_controller.dart`

- [ ] **Step 1: Create the file**

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';

/// Owns a media_kit [Player] for one watch session: opens a source with its
/// headers + subtitles, persists resume position, advances on completion, and
/// falls through to the next source if one fails to start (covers dead/DRM
/// sources).
class PlayerController extends ChangeNotifier {
  PlayerController({
    required this.sourceId,
    required this.episodes,
    required this.resume,
    required Future<List<VideoSource>> Function(String episodeUrl) resolveSources,
  }) : _resolveSources = resolveSources;

  final String sourceId;
  final List<Episode> episodes;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) _resolveSources;

  final Player player = Player();
  late final VideoController videoController = VideoController(player);

  int currentIndex = 0;
  List<VideoSource> sources = const [];
  VideoSource? active;
  String? error;
  bool loadingSources = false;

  final List<StreamSubscription> _subs = [];
  Duration _lastPos = Duration.zero;
  Duration _lastDur = Duration.zero;

  Episode get currentEpisode => episodes[currentIndex];

  void init(int index) {
    _subs.add(player.stream.position.listen((p) => _lastPos = p));
    _subs.add(player.stream.duration.listen((d) => _lastDur = d));
    _subs.add(player.stream.completed.listen((done) {
      if (done) playNext();
    });
    _subs.add(player.stream.error.listen((e) => _onPlaybackError(e)));
    openEpisode(index);
  }

  /// Resolves sources for [index] and starts the best one.
  Future<void> openEpisode(int index) async {
    await _persist();
    currentIndex = index;
    error = null;
    loadingSources = true;
    sources = const [];
    active = null;
    notifyListeners();
    try {
      final resolved = await _resolveSources(currentEpisode.url);
      sources = resolved;
      loadingSources = false;
      final pick = pickDefault(resolved);
      if (pick == null) {
        error = 'No playable sources for this episode.';
        notifyListeners();
        return;
      }
      await _open(pick);
    } catch (e) {
      loadingSources = false;
      error = 'Could not load sources: $e';
      notifyListeners();
    }
  }

  /// Switch to a specific source (sub/dub or quality change), preserving position.
  Future<void> switchSource(VideoSource s) => _open(s, seekTo: _lastPos);

  Future<void> _open(VideoSource s, {Duration? seekTo}) async {
    active = s;
    error = null;
    notifyListeners();
    final mark = resume.get(sourceId, currentEpisode.id);
    final start = seekTo ??
        ((mark != null && !mark.finished) ? mark.position : Duration.zero);
    await player.open(
      Media(s.url, httpHeaders: s.headers, start: start > Duration.zero ? start : null),
    );
    // Attach the first soft subtitle, if any.
    if (s.subtitles.isNotEmpty) {
      final sub = s.subtitles.firstWhere((x) => x.isDefault, orElse: () => s.subtitles.first);
      await player.setSubtitleTrack(
          SubtitleTrack.uri(sub.url, title: sub.label ?? sub.lang, language: sub.lang));
    }
  }

  /// Try the next source after the [failed] one (dead/DRM/unsupported).
  Future<void> _onPlaybackError(String e) async {
    debugPrint('[player] error: $e');
    final remaining = sources.where((s) => s != active).toList();
    final next = pickDefault(remaining);
    if (next != null) {
      await _open(next);
    } else {
      error = 'Playback failed: $e';
      notifyListeners();
    }
  }

  Future<void> playNext() async {
    if (currentIndex + 1 < episodes.length) {
      await openEpisode(currentIndex + 1);
    }
  }

  Future<void> _persist() async {
    if (_lastDur > Duration.zero) {
      await resume.save(sourceId, currentEpisode.id, _lastPos, _lastDur);
    }
  }

  @override
  void dispose() {
    _persist();
    for (final s in _subs) {
      s.cancel();
    }
    player.dispose();
    super.dispose();
  }
}
```

- [ ] **Step 2: Verify**

Run: `flutter analyze lib/features/player/player_controller.dart`
Expected: `No issues found!` (If `player.stream.error` is named differently in the resolved media_kit version, the analyzer will flag it — adjust to the version's error stream; the analyzer is the gate.)

- [ ] **Step 3: Commit**

```bash
git add lib/features/player/player_controller.dart
git commit -m "feat(2b): PlayerController — open/switch/resume/autoplay/try-next-source"
```

---

## Task 6: PlayerScreen (Video widget + pickers + loading state)

**Files:**
- Create: `lib/features/player/player_screen.dart`

- [ ] **Step 1: Create the file**

```dart
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import 'player_controller.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.sourceId,
    required this.episodes,
    required this.startIndex,
    required this.resume,
    required this.resolveSources,
  });

  final String sourceId;
  final List<Episode> episodes;
  final int startIndex;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlayerController _c;

  @override
  void initState() {
    super.initState();
    _c = PlayerController(
      sourceId: widget.sourceId,
      episodes: widget.episodes,
      resume: widget.resume,
      resolveSources: widget.resolveSources,
    )..init(widget.startIndex);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _openPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) {
        final kinds = availableKinds(_c.sources);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final k in kinds)
                for (final s in sortByQuality(sourcesForKind(_c.sources, k)))
                  ListTile(
                    dense: true,
                    leading: Icon(s == _c.active ? Icons.check : null),
                    title: Text('${k.name.toUpperCase()} • '
                        '${s.quality?.isNotEmpty == true ? s.quality : s.container.name}'),
                    onTap: () {
                      Navigator.pop(context);
                      _c.switchSource(s);
                    },
                  ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          if (_c.error != null) {
            return _Centered(child: Text(_c.error!, style: const TextStyle(color: Colors.white)));
          }
          if (_c.loadingSources) {
            return const _Centered(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Resolving sources…', style: TextStyle(color: Colors.white70)),
              ]),
            );
          }
          return SafeArea(
            child: Column(
              children: [
                Expanded(child: Video(controller: _c.videoController)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Ep ${_c.currentEpisode.number ?? ''} • '
                            '${_c.active?.kind.name ?? ''} '
                            '${_c.active?.quality ?? ''}',
                            style: const TextStyle(color: Colors.white70)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.high_quality, color: Colors.white),
                        onPressed: _c.sources.isEmpty ? null : _openPicker,
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next, color: Colors.white),
                        onPressed: _c.playNext,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: Center(child: child),
      );
}
```

- [ ] **Step 2: Verify**

Run: `flutter analyze lib/features/player/`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/features/player/player_screen.dart
git commit -m "feat(2b): PlayerScreen — Video widget, sub/dub+quality picker, next, loading state"
```

---

## Task 7: HomeScreen (search + results grid)

**Files:**
- Create: `lib/features/home/home_screen.dart`

- [ ] **Step 1: Create the file**

```dart
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/repository/source_repository.dart';
import '../detail/detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _repo = sl<SourceRepository>();
  final _controller = TextEditingController();
  Future<List<MediaItem>>? _results;

  void _search(String q) {
    if (q.trim().isEmpty) return;
    setState(() => _results = _repo.search(q.trim()));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: const InputDecoration(
            hintText: 'Search $kAppName…',
            border: InputBorder.none,
          ),
        ),
        actions: [IconButton(icon: const Icon(Icons.search), onPressed: () => _search(_controller.text))],
      ),
      body: _results == null
          ? const Center(child: Text('Search for an anime to start.'))
          : FutureBuilder<List<MediaItem>>(
              future: _results,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Search failed: ${snap.error}'));
                }
                final items = snap.data ?? const [];
                if (items.isEmpty) return const Center(child: Text('No results.'));
                return GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, childAspectRatio: 0.62,
                    crossAxisSpacing: 8, mainAxisSpacing: 8),
                  itemCount: items.length,
                  itemBuilder: (context, i) => _PosterCard(item: items[i]),
                );
              },
            ),
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({required this.item});
  final MediaItem item;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => DetailScreen(item: item))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: item.cover == null
                  ? const ColoredBox(color: Colors.black26)
                  : CachedNetworkImage(
                      imageUrl: item.cover!,
                      httpHeaders: item.coverHeaders,
                      fit: BoxFit.cover, width: double.infinity,
                      errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black26),
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Add `cached_network_image` dep** (used above). In `pubspec.yaml` under `dependencies:`:
```yaml
  cached_network_image: ^3.4.1
```
Run: `flutter pub get` → `Got dependencies!`

- [ ] **Step 3: Verify** (DetailScreen is created in Task 8; this will not analyze clean until then — that's expected.)

Run: `flutter analyze lib/features/home/home_screen.dart`
Expected: one error about `detail_screen.dart` not existing yet — acceptable; resolved in Task 8. Do NOT stub DetailScreen here.

- [ ] **Step 4: Commit**

```bash
git add lib/features/home/home_screen.dart pubspec.yaml pubspec.lock
git commit -m "feat(2b): HomeScreen — search + results grid"
```

---

## Task 8: DetailScreen (sub/dub toggle + episodes → open player)

**Files:**
- Create: `lib/features/detail/detail_screen.dart`

- [ ] **Step 1: Create the file**

```dart
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/resume_store.dart';
import '../../core/repository/source_repository.dart';
import '../player/player_screen.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.item});
  final MediaItem item;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final _repo = sl<SourceRepository>();
  Future<MediaDetail>? _detail;

  @override
  void initState() {
    super.initState();
    _detail = _repo.detail(widget.item.url);
  }

  void _openPlayer(List<Episode> episodes, int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        sourceId: widget.item.sourceId,
        episodes: episodes,
        startIndex: index,
        resume: sl<ResumeStore>(),
        resolveSources: _repo.sources,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.item.title)),
      body: FutureBuilder<MediaDetail>(
        future: _detail,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Failed to load: ${snap.error}'));
          }
          final detail = snap.data!;
          final eps = detail.episodes;
          return ListView.builder(
            itemCount: eps.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(detail.title, style: Theme.of(context).textTheme.titleLarge),
                      if ((detail.description ?? '').isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(detail.description!, maxLines: 4, overflow: TextOverflow.ellipsis),
                      ],
                      const SizedBox(height: 8),
                      Text('${eps.length} episodes',
                          style: Theme.of(context).textTheme.labelMedium),
                      const Divider(),
                    ],
                  ),
                );
              }
              final ep = eps[i - 1];
              return ListTile(
                title: Text(ep.title),
                trailing: const Icon(Icons.play_arrow),
                onTap: () => _openPlayer(eps, i - 1),
              );
            },
          );
        },
      ),
    );
  }
}
```

- [ ] **Step 2: Verify the whole project analyzes** (Home + Detail + Player now all exist)

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/features/detail/detail_screen.dart
git commit -m "feat(2b): DetailScreen — episode list → open player"
```

---

## Task 9: Launch into HomeScreen + run all tests

**Files:**
- Modify: `lib/main.dart`

- [ ] **Step 1: Point the app at HomeScreen**

In `lib/main.dart`, replace the `import 'dev/dev_slice_screen.dart';` with:
```dart
import 'features/home/home_screen.dart';
```
And change the `home:` of the `MaterialApp` from `const DevSliceScreen()` to:
```dart
        home: const HomeScreen(),
```

- [ ] **Step 2: Delete the throwaway dev slice**

```bash
git rm lib/dev/dev_slice_screen.dart
```

- [ ] **Step 3: Verify**

Run: `flutter analyze`
Expected: `No issues found!`
Run: `flutter test`
Expected: all pass (12 prior + 5 source_selection + 3 resume_store = 20).

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart
git commit -m "feat(2b): launch into HomeScreen; remove dev slice"
```

---

## Task 10: On-device smoke — watch a real episode

Manual verification (media_kit + UI need a device). No code; this is the acceptance gate.

- [ ] **Step 1: Run on the iOS simulator** (from a terminal with the CocoaPods env fix)

Run:
```bash
cd "/Users/krishnavishwakarma/Programming Playground/watch_app"
env -u GEM_HOME -u GEM_PATH PATH="/opt/homebrew/bin:$PATH" flutter run -d "iPhone 15 Pro Max"
```

- [ ] **Step 2: Verify the flow**

1. Home screen → type "one piece" → Search → a grid of posters appears.
2. Tap a poster → Detail screen → "1169 episodes" + an episode list.
3. Tap Episode 1 → Player screen shows "Resolving sources…" (~up to 20s, per the 2A learning), then **video plays**.
4. The quality icon opens a sub/dub + quality picker; selecting another entry reloads at the same position.
5. Backing out and reopening the same episode resumes near where you left off.

Expected: an episode actually plays on-device. If the chosen source fails, the controller auto-advances to the next source (watch the logs for `[player] error:` followed by playback starting).

- [ ] **Step 3: Record the result**

If it plays: 2B is done. If a specific step fails, capture the on-screen error + the `flutter run` logs (the `[fetch]`/`[player]` lines) and debug from there.

---

## Self-review (spec coverage)

- **§3 player module** (media_kit, custom headers via `Media(httpHeaders:)`, soft subtitles via `setSubtitleTrack`, sub/dub + quality switching, resume, autoplay-next, DRM/dead-source skip via try-next) → Tasks 1, 5, 6, 3. ✓
- **§4 minimal UI & navigation** (Home search, Detail sub/dub+episodes, Navigator) → Tasks 7, 8; SourceRepository Task 4. ✓
- **§5 structure** → matches the file map. ✓
- **§7 Plan 2B** B1 player (1,5,6) · B2 repository+Home+Detail (4,7,8) · B3 resume+autoplay+smoke (3,5,9,10). ✓
- **2A learning** (slow source resolution) → loading state (Task 6) + try-next (Task 5). ✓
- Sub/dub toggle on Detail: the picker on the Player covers kind selection; Detail defaults to `sub`. Acceptable for functional-first (a Detail-level toggle is a trivial later add).

**Type/name consistency:** `pickDefault/sortByQuality/sourcesForKind/availableKinds` (Task 2) are used in Tasks 5–6. `ResumeStore.get/save` + `ResumeMark.position/duration/finished` (Task 3) used in Task 5. `SourceRepository.search/detail/episodes/sources` (Task 4) used in Tasks 7,8 + passed as `resolveSources`. `PlayerController` ctor params match `PlayerScreen`'s construction. `Media(httpHeaders:, start:)`, `SubtitleTrack.uri`, `VideoController`, `Video(controller:)`, `player.stream.{position,duration,completed,error}` are the media_kit API — Task 5/6 `flutter analyze` is the gate; if the resolved media_kit version renames a member, adjust to that version (no other task depends on the exact stream name).

**Placeholder scan:** every code step has full code; the only intentional "fails to analyze until next task" is Task 7 (depends on Task 8's DetailScreen), called out explicitly. No TBD/TODO.

## Notes / risks

- **media_kit API drift:** if `flutter pub get` resolves a media_kit major that renames `player.stream.error` or `Media(start:)`, Task 5/6 analyze will flag it; adjust to the resolved version's API. Pin versions are current-stable as written.
- **Source-resolution latency:** ~20s worst case (dead AllAnime clock backend). Mitigated by a loading state; a future optimization (return sources as they resolve / drop slow backends) is out of scope for 2B.
- **iOS Simulator playback:** libmpv via media_kit_libs_video works on the simulator; if a specific codec misbehaves on the sim, verify on a physical device.
