// Task 11: the Detail screen routes reading-type (manga/novel) titles to the
// reader instead of the video player.
//
// Harness mirrors detail_screen_tv_test.dart's lightweight GetIt stubs (no
// Hive, no platform channels), but pumps the PHONE DetailScreen with
// AppMode(isTv: false). Unlike DetailScreenTv (which reads a DetailCubit from
// an ancestor BlocProvider), DetailScreen builds its own cubit internally, so
// we just pump DetailScreen(item:) directly and let it load.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/core/reading/read_store.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/trailer/trailer_service.dart';
import 'package:watch_app/features/detail/detail_screen.dart';
import 'package:watch_app/features/player/player_screen.dart';
import 'package:watch_app/features/reader/novel_reader_screen.dart';

// ── Minimal stubs — no Hive, no platform channels, no network ───────────────

/// Stub [SourceRepository] that returns a pre-built [MediaDetail]. Doesn't
/// implement `chapterText` — a tap into NovelReaderScreen drives it into its
/// own already-tested error state (see novel_reader_test.dart) via the
/// inherited noSuchMethod, which is exactly what we want: we're only proving
/// the PUSH happened, not re-testing the reader's load path.
///
/// `prefetch` calls are recorded (not just no-op'd) so a test can assert
/// _maybePrefetch never fires `sources()`-resolution against a reading
/// title's chapter URL — Finding 1 of the fix round.
class _StubSourceRepository implements SourceRepository {
  _StubSourceRepository(this._detail);
  final MediaDetail _detail;
  final List<String> prefetchCalls = [];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async => _detail;

  @override
  void prefetch(String url, {String? sourceId}) {
    prefetchCalls.add(url);
  }

  @override
  String get sourceId => 'test';

  @override
  bool hasSource(String id) => false;

  @override
  String displayName(String id) => id;

  @override
  List<({String id, String name})> get loadedSources => const [];
}

class _FakeTitlePrefs extends TitlePrefsStore {
  @override
  String? category(String s, String u) => null;

  @override
  Future<void> setCategory(String s, String u, String c) async {}
}

class _FakeMyListStore implements MyListStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool contains(MediaItem m) => false;

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

class _FakeListStatusStore implements ListStatusStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  WatchStatus? statusOf(MediaItem m) => null;

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

class _FakeResumeStore implements ResumeStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  ResumeMark? get(String sourceId, String showId, String episodeId) => null;
}

/// [ReadStore] stub for the Part E (Task 12) resume test — [marks] is keyed
/// by chapterId only (the tests here use a single show), mirroring the shape
/// of a saved {pos,total} mark without touching a real Hive box.
class _FakeReadStore extends ReadStore {
  _FakeReadStore(this.marks);
  final Map<String, ({int pos, int total})> marks;

  @override
  ({int pos, int total})? get(String sourceId, String showId, String chapterId) =>
      marks[chapterId];

  @override
  bool finished(String sourceId, String showId, String chapterId) {
    final m = marks[chapterId];
    if (m == null || m.total <= 0) return false;
    if (m.total == 1000) return m.pos >= 950;
    return m.pos >= m.total - 1;
  }
}

/// [ReadHistory] stub for the ReadHistory-fallback resume test — [entry], when
/// set, is what `_readResumeIndex` finds once it falls off the end of an empty
/// [ReadStore]. Doesn't touch Hive (the real ReadHistory only does that inside
/// methods this override bypasses), so no ReadHistory.init() is needed here.
class _FakeReadHistory extends ReadHistory {
  _FakeReadHistory([this.entry]) : super(SupabaseService(), () => null);
  final ReadEntry? entry;

  @override
  ReadEntry? get(String sourceId, String showId) => entry;
}

class _FakeProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;

  @override
  List<ProviderRegistryEntry> getAll() => const [];
}

class _FakeCloudStreamManager extends ChangeNotifier
    implements CloudStreamManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  BaseProvider? get(String sourceId) => null;

  @override
  String? repoNameForSourceId(String sourceId) => null;

  @override
  List<CloudStreamProvider> get enabled => const [];
}

class _FakeDownloadManager extends ChangeNotifier implements DownloadManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  DownloadRecord? recordFor(String sourceId, String showId, String episodeId) =>
      null;
}

/// Never resolves a trailer — keeps the hero on its static (empty-cover)
/// backdrop so the media_kit-backed `_HeroTrailer` is never built, and
/// avoids a real network call to AniList/TMDB.
class _FakeTrailerService extends TrailerService {
  _FakeTrailerService() : super(Dio());

  @override
  Future<String?> youtubeId({
    required String title,
    String? englishTitle,
    required ProviderType type,
    String? year,
  }) async => null;
}

/// Hive-backed in reality; overrides just the getters _openPlayer's
/// preserved anime path reads, matching the real defaults.
class _FakePlaybackPrefs extends PlaybackPrefs {
  @override
  bool get autoAddToMyList => false;

  @override
  String get defaultCategory => 'sub';
}

// ── Test data ────────────────────────────────────────────────────────────────

const _novelItem = MediaItem(
  id: 'test-novel',
  title: 'Test Novel',
  url: 'http://test/novel',
  type: ProviderType.novel,
  sourceId: 'test',
);

const _novelDetail = MediaDetail(
  id: 'test-novel',
  title: 'Test Novel',
  url: 'http://test/novel',
  type: ProviderType.novel,
  sourceId: 'test',
  episodes: [
    Episode(id: 'c1', title: 'Chapter 1', url: '/c1', number: 1),
    Episode(id: 'c2', title: 'Chapter 2', url: '/c2', number: 2),
  ],
);

const _animeItem = MediaItem(
  id: 'test-anime',
  title: 'Test Anime',
  url: 'http://test/anime',
  type: ProviderType.anime,
  sourceId: 'test',
);

const _animeDetail = MediaDetail(
  id: 'test-anime',
  title: 'Test Anime',
  url: 'http://test/anime',
  type: ProviderType.anime,
  sourceId: 'test',
  episodes: [
    Episode(id: 'e1', title: 'Episode 1', url: '/e1', number: 1),
    Episode(id: 'e2', title: 'Episode 2', url: '/e2', number: 2),
  ],
);

/// Records pushes so the anime-regression test can prove `_openPlayer`'s
/// original path ran (reached its final `Navigator.push`) WITHOUT actually
/// building `PlayerScreen`'s STATE — which wires up media_kit + a dozen more
/// singletons that have no place in a lightweight widget test. `didPush`
/// fires synchronously as part of `Navigator.push`, before any rebuild, so
/// checking it right after `tester.tap()` (with no follow-up `pump()`) never
/// triggers the destination route's build. Storing the route (not just a
/// count) lets the test call its `builder` directly afterward — that
/// constructs the `PlayerScreen` WIDGET (a plain field-holding object) without
/// ever creating its `State`, so it's safe to assert the concrete type.
class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late Directory readerPrefsDir;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => '/tmp',
        );

    await sl.reset();
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<ListStatusStore>(_FakeListStatusStore());
    sl.registerSingleton<ResumeStore>(_FakeResumeStore());
    sl.registerSingleton<ProviderRegistry>(_FakeProviderRegistry());
    sl.registerSingleton<CloudStreamManager>(_FakeCloudStreamManager());
    sl.registerSingleton<DownloadManager>(_FakeDownloadManager());
    sl.registerSingleton<TitlePrefsStore>(_FakeTitlePrefs());
    sl.registerSingleton<PlaybackPrefs>(_FakePlaybackPrefs());
    sl.registerSingleton<TrailerService>(_FakeTrailerService());
    sl.registerSingleton<TrackerHub>(TrackerHub(const []));
    // A real (temp-dir-backed) ReaderPrefs, not a hand-rolled fake — the
    // novel reader reads a growing list of its getters (comfort, typography,
    // pagination…) on mount, and every one already has a sensible default.
    // Same disposable-Hive pattern as read_history_test.dart.
    readerPrefsDir = await Directory.systemTemp.createTemp('reader_prefs_test');
    Hive.init(readerPrefsDir.path);
    await ReaderPrefs.init();
    sl.registerSingleton<ReaderPrefs>(ReaderPrefs());
    // Empty by default (no saved reading position) — the novel test below
    // just needs this registered so _readResumeIndex's sl<ReadStore>() call
    // doesn't blow up; the dedicated resume test overrides it with marks.
    sl.registerSingleton<ReadStore>(_FakeReadStore(const {}));
    // No cloud-synced entry by default — _readResumeIndex falls back to this
    // whenever ReadStore has no local mark, so it must always be registered
    // for a reading title; the dedicated fallback test overrides it.
    sl.registerSingleton<ReadHistory>(_FakeReadHistory());
    // Only needed for the anime test: building the pushed PlayerScreen WIDGET
    // (not its State — see _RecordingNavigatorObserver) still evaluates every
    // sl<T>() in _openPlayer's constructor-argument list, including this one.
    sl.registerSingleton<WatchHistory>(
      WatchHistory(SupabaseService(), () => null),
    );
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await sl.reset();
    await Hive.deleteFromDisk();
    if (await readerPrefsDir.exists()) {
      await readerPrefsDir.delete(recursive: true);
    }
  });

  testWidgets(
    'novel detail shows Read (not Play), no Sub/Dub toggle, no download '
    'button, and tapping a chapter pushes NovelReaderScreen',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final stub = _StubSourceRepository(_novelDetail);
      sl.registerSingleton<SourceRepository>(stub);

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _novelItem)),
      );
      await tester.pump(); // let the cubit's load() resolve
      await tester.pump(); // flush _maybePrefetch's post-frame callback, if any

      expect(find.text('Read'), findsWidgets);
      expect(find.text('Play'), findsNothing);

      // Finding 1: merely opening a reading title's detail must never fire
      // video-source prefetch against a chapter URL.
      expect(stub.prefetchCalls, isEmpty);

      // No Sub/Dub toggle anywhere on the page.
      expect(find.text('Sub'), findsNothing);
      expect(find.text('Dub'), findsNothing);

      // No download affordance — main button or per-chapter icon (both use
      // this glyph when shown).
      expect(find.byIcon(Icons.file_download_outlined), findsNothing);

      // Tapping a chapter row pushes NovelReaderScreen.
      expect(find.byType(NovelReaderScreen), findsNothing);
      expect(find.textContaining('Chapter 1'), findsOneWidget);
      await tester.tap(find.textContaining('Chapter 1'));
      await tester.pumpAndSettle();
      expect(find.byType(NovelReaderScreen), findsOneWidget);
    },
  );

  testWidgets(
    'a ReadStore mark resumes from the last-read chapter (not chapter 1) '
    'and relabels the button Continue',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      sl.registerSingleton<SourceRepository>(
        _StubSourceRepository(_novelDetail),
      );
      // Chapter 1 (c1) is saved as FINISHED (pos >= total-1) — the reader
      // should resume on chapter 2 (c2), not restart chapter 1. Overrides
      // setUp's empty default.
      sl.unregister<ReadStore>();
      sl.registerSingleton<ReadStore>(
        _FakeReadStore({'c1': (pos: 19, total: 20)}),
      );

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _novelItem)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Continue'), findsOneWidget);
      expect(find.text('Read'), findsNothing); // relabelled, not a fresh title

      await tester.tap(find.text('Continue').first);
      await tester.pumpAndSettle();

      final reader = tester.widget<NovelReaderScreen>(
        find.byType(NovelReaderScreen),
      );
      expect(reader.startIndex, 1); // resumed onto chapter 2 (index 1)
      expect(reader.chapters.length, 2); // still the full chapter list
    },
  );

  testWidgets(
    'with no ReadStore mark, the Read button falls back to ReadHistory — '
    'the cloud-synced last-read chapter — instead of starting at chapter 1',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      sl.registerSingleton<SourceRepository>(
        _StubSourceRepository(_novelDetail),
      );
      // ReadStore stays empty (setUp's default) — nothing marked on THIS
      // device — but ReadHistory (synced from elsewhere) says chapter 1 was
      // finished, so the reader should resume on chapter 2, same as a local
      // mark would, and the button should read Continue.
      sl.unregister<ReadHistory>();
      sl.registerSingleton<ReadHistory>(
        _FakeReadHistory(
          ReadEntry(
            sourceId: 'test',
            showId: 'test-novel',
            title: 'Test Novel',
            chapterId: 'c1',
            chapterUrl: '/c1',
            pos: 19,
            total: 20, // finished
            updatedMs: 1,
            type: ProviderType.novel,
          ),
        ),
      );

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _novelItem)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Continue'), findsOneWidget);

      await tester.tap(find.text('Continue').first);
      await tester.pumpAndSettle();

      final reader = tester.widget<NovelReaderScreen>(
        find.byType(NovelReaderScreen),
      );
      expect(reader.startIndex, 1); // resumed onto chapter 2 (index 1)
    },
  );

  testWidgets(
    'anime detail keeps Play (not Read) and still pushes the player — the '
    'hard constraint: anime/movie behaviour is unchanged',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      sl.registerSingleton<SourceRepository>(
        _StubSourceRepository(_animeDetail),
      );

      final observer = _RecordingNavigatorObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: const DetailScreen(item: _animeItem),
        ),
      );
      await tester.pump(); // let the cubit's load() resolve

      expect(find.text('Play'), findsWidgets);
      expect(find.text('Read'), findsNothing);

      final before = observer.pushed.length;
      // No pump() after this tap on purpose — see _RecordingNavigatorObserver.
      await tester.tap(find.text('Play').first);
      expect(observer.pushed.length, before + 1);

      // Precise, not just "something got pushed": build the pushed route's
      // widget (never its State — see the class doc above) and assert it's
      // actually PlayerScreen, so a refactor that pushed some other route
      // would fail this test.
      final pushedRoute = observer.pushed.last as MaterialPageRoute;
      final pushedWidget = pushedRoute.builder(
        tester.element(find.byType(DetailScreen)),
      );
      expect(pushedWidget, isA<PlayerScreen>());
    },
  );

  // ── Chapter row (reading-only minimal design) ──────────────────────────────
  //
  // The reading list swaps _EpisodeRow for _ChapterRow. Both are private, so
  // these assert what's actually rendered: the portrait cover's key + size,
  // the absence of the play overlay, and the unprefixed title.

  /// The key _ChapterRow puts on its 44×62 portrait cover — the marker that
  /// separates a chapter row from an episode row.
  const chapterCover = Key('chapterCover');

  MediaDetail novelWithDates(String? date) => MediaDetail(
    id: 'test-novel',
    title: 'Test Novel',
    url: 'http://test/novel',
    type: ProviderType.novel,
    sourceId: 'test',
    episodes: [
      Episode(id: 'c1', title: 'Chapter 1', url: '/c1', number: 1, date: date),
      Episode(id: 'c2', title: 'Chapter 2', url: '/c2', number: 2, date: date),
    ],
  );

  testWidgets(
    'reading mode renders the minimal chapter row: 44×62 portrait cover, no '
    'play overlay, no "1." title prefix, and a relative date',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // Just past the 2-day boundary so the bucket can't flake either way.
      final twoDaysAgo = DateTime.now()
          .subtract(const Duration(days: 2, hours: 1))
          .toIso8601String();
      sl.registerSingleton<SourceRepository>(
        _StubSourceRepository(novelWithDates(twoDaysAgo)),
      );

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _novelItem)),
      );
      await tester.pump();
      await tester.pump();

      // One portrait cover per chapter, at the agreed size.
      expect(find.byKey(chapterCover), findsNWidgets(2));
      expect(tester.getSize(find.byKey(chapterCover).first), const Size(44, 62));

      // No ▶ anywhere on a reading page — not in the row, and the hero button
      // uses the book glyph.
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);

      // Title as the source gave it; the number is already in it.
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('1. Chapter 1'), findsNothing);

      // Line 2 is the relative date.
      expect(find.text('2 days ago'), findsNWidgets(2));

      // And the episode row's 116px landscape thumb is nowhere to be seen.
      expect(
        find.byWidgetPredicate((w) => w is SizedBox && w.width == 116),
        findsNothing,
      );
    },
  );

  testWidgets(
    'the chapter row drops its meta line when the source has no date',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      sl.registerSingleton<SourceRepository>(
        _StubSourceRepository(novelWithDates(null)),
      );

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _novelItem)),
      );
      await tester.pump();
      await tester.pump();

      // Row still renders; the second line simply isn't there.
      expect(find.byKey(chapterCover), findsNWidgets(2));
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.textContaining('ago'), findsNothing);
      expect(find.textContaining('Today'), findsNothing);
    },
  );

  testWidgets(
    'read chapters dim their cover and a part-read one gets the accent bar '
    '(state comes from ReadStore, not the video ResumeStore)',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      sl.registerSingleton<SourceRepository>(
        _StubSourceRepository(novelWithDates(null)),
      );
      sl.unregister<ReadStore>();
      sl.registerSingleton<ReadStore>(
        _FakeReadStore({
          'c1': (pos: 19, total: 20), // finished → read
          'c2': (pos: 5, total: 10), // halfway → in progress
        }),
      );

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _novelItem)),
      );
      await tester.pump();
      await tester.pump();

      Opacity coverOpacity(int i) => tester.widget<Opacity>(
        find.descendant(
          of: find.byKey(chapterCover).at(i),
          matching: find.byType(Opacity),
        ),
      );
      expect(coverOpacity(0).opacity, 0.45); // chapter 1 is read
      expect(coverOpacity(1).opacity, 1.0); // chapter 2 isn't

      final bar = tester.widget<FractionallySizedBox>(
        find.byType(FractionallySizedBox),
      );
      expect(bar.widthFactor, 0.5); // 5 of 10 pages
      expect(tester.getSize(find.byType(FractionallySizedBox)).height, 2);
    },
  );

  testWidgets(
    'HARD CONSTRAINT: the anime episode row is untouched — 116×16:9 thumb '
    'with the play overlay, numbered title, and no chapter cover',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      sl.registerSingleton<SourceRepository>(
        _StubSourceRepository(_animeDetail),
      );

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _animeItem)),
      );
      await tester.pump();
      await tester.pump();

      // The reading row must never appear on an anime title.
      expect(find.byKey(chapterCover), findsNothing);

      // The landscape thumbnail, still 116 wide at 16:9, one per episode.
      final thumb = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 116,
      );
      expect(thumb, findsNWidgets(2));
      expect(tester.getSize(thumb.first), const Size(116, 116 * 9 / 16));

      // …with the play-circle still centred on it.
      expect(
        find.descendant(
          of: thumb.first,
          matching: find.byIcon(Icons.play_arrow_rounded),
        ),
        findsOneWidget,
      );

      // …and the episode heading. A source title that is only a generic
      // "Episode N" collapses to that alone — the row used to double it up
      // as "1. Episode 1". A real title still reads "1. Real Name".
      expect(find.text('Episode 1'), findsOneWidget);
      expect(find.text('Episode 2'), findsOneWidget);
    },
  );
}
