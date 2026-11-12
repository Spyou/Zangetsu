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
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/metadata/episode_metadata_service.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
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
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/trailer/trailer_service.dart';
import 'package:watch_app/features/detail/detail_screen.dart';
import 'package:watch_app/features/player/player_screen.dart';
import 'package:watch_app/features/player/mpv_player_pool.dart';
import 'package:watch_app/features/reader/novel_reader_screen.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';

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
  final List<String> sourceCalls = [];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  /// "Open in browser" joins a relative chapter key onto this. Empty means the
  /// source has no site, which is the honest default for a stub — the row is
  /// then hidden rather than opening nothing.
  @override
  String baseUrlFor(String sourceId) => '';

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
    bool Function()? abandoned,
  }) async => _detail;

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) async {
    sourceCalls.add(episodeUrl);
    return const [
      VideoSource(url: 'https://test/video.m3u8', quality: '1080p'),
    ];
  }

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
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  bool contains(MediaItem m) => false;

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

class _FakeListStatusStore implements ListStatusStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  WatchStatus? statusOf(MediaItem m) => null;

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

class _FakeResumeStore implements ResumeStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

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
  ({int pos, int total})? get(
    String sourceId,
    String showId,
    String chapterId,
  ) => marks[chapterId];

  @override
  bool finished(String sourceId, String showId, String chapterId) {
    final m = marks[chapterId];
    if (m == null || m.total <= 0) return false;
    if (m.total == 1000) return m.pos >= 950;
    return m.pos >= m.total - 1;
  }
}

/// Records the showId used for READS and for WRITES separately.
///
/// The plain [_FakeReadStore] keys on chapterId alone, so it cannot notice the
/// two disagreeing — which is exactly the bug this guards: marking a chapter
/// wrote under the video key (item.url) while the row read under the reading
/// key (item.id), so nothing ever dimmed.
class _KeyedReadStore extends ReadStore {
  final List<String> readShowIds = [];
  final List<String> writtenShowIds = [];
  final Set<String> _done = {};

  @override
  ({int pos, int total})? get(String s, String showId, String chapterId) =>
      null;

  @override
  bool finished(String s, String showId, String chapterId) {
    readShowIds.add(showId);
    return _done.contains('$showId::$chapterId');
  }

  @override
  Future<void> setRead(
    String s,
    String showId,
    String chapterId, {
    required bool read,
  }) async {
    writtenShowIds.add(showId);
    final k = '$showId::$chapterId';
    read ? _done.add(k) : _done.remove(k);
  }
}

/// Verifies reading resume uses the resolved provider source, not the
/// metadata/catalogue pseudo-source on [MediaItem].
class _SourceKeyedReadStore extends ReadStore {
  _SourceKeyedReadStore({
    required this.sourceId,
    required this.showId,
    required this.marks,
  });

  final String sourceId;
  final String showId;
  final Map<String, ({int pos, int total})> marks;

  @override
  ({int pos, int total})? get(
    String sourceId,
    String showId,
    String chapterId,
  ) {
    if (sourceId != this.sourceId || showId != this.showId) return null;
    return marks[chapterId];
  }

  @override
  bool finished(String sourceId, String showId, String chapterId) {
    final mark = get(sourceId, showId, chapterId);
    if (mark == null || mark.total <= 0) return false;
    return mark.total == 1000 ? mark.pos >= 950 : mark.pos >= mark.total - 1;
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
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;

  @override
  List<ProviderRegistryEntry> getAll() => const [];
}

class _FakeCloudStreamManager extends ChangeNotifier
    implements CloudStreamManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

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
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  DownloadRecord? recordFor(String sourceId, String showId, String episodeId) =>
      null;

  @override
  Future<DownloadRecord?> finishedForEpisode({
    required String sourceId,
    required String showId,
    required String episodeId,
    String? episodeUrl,
    int? malId,
    double? episodeNumber,
  }) async => null;
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
  _FakePlaybackPrefs({this.batchStyle = 'classic', this.playerPackage = ''});

  final String playerPackage;
  @override
  String get externalPlayerPackage => playerPackage;
  @override
  bool get styledSubtitles => false;

  final String batchStyle;

  @override
  bool get autoAddToMyList => false;

  @override
  String get defaultCategory => 'sub';

  @override
  String get batchDownloadStyle => batchStyle;
}

class _WarmupPool extends MpvPlayerPool {
  int preparations = 0;
  int clears = 0;
  @override
  void warmUp({required bool libass}) => preparations++;
  @override
  Future<void> clear() async => clears++;
}

class _DownloadRepository extends _StubSourceRepository {
  _DownloadRepository(this.sub, this.dub, {this.failDub = false}) : super(sub);
  final bool failDub;
  final MediaDetail sub;
  final MediaDetail dub;
  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
    bool Function()? abandoned,
  }) async {
    if (category == 'dub' && failDub) throw StateError('Dub unavailable');
    return category == 'dub' ? dub : sub;
  }

  @override
  Future<List<VideoSource>> sources(
    String url, {
    String? sourceId,
    bool fast = false,
  }) async => const [
    VideoSource(url: 'https://test/a.mp4', label: 'Mirror A', quality: '720p'),
    VideoSource(
      url: 'https://test/b.mp4',
      label: 'Mirror B',
      quality: '720p',
      headers: {'Referer': 'https://test/'},
    ),
  ];
}

class _RecordingDownloads extends _FakeDownloadManager {
  Symbol? method;
  Map<Symbol, dynamic> arguments = {};
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #enqueueSource ||
        invocation.memberName == #enqueueEpisodes) {
      method = invocation.memberName;
      arguments = invocation.namedArguments;
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
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

/// A source with two scanlation groups: every chapter listed once per group,
/// which is how they really arrive. The row after Alpha's chapter 1 is Beta's
/// chapter 1 — the same chapter again.
const _multiGroupDetail = MediaDetail(
  id: 'test-novel',
  title: 'Test Novel',
  url: 'http://test/novel',
  type: ProviderType.novel,
  sourceId: 'test',
  episodes: [
    Episode(
      id: 'c1a',
      title: 'Chapter 1',
      url: '/c1a',
      number: 1,
      scanlator: 'Alpha',
    ),
    Episode(
      id: 'c1b',
      title: 'Chapter 1',
      url: '/c1b',
      number: 1,
      scanlator: 'Beta',
    ),
    Episode(
      id: 'c2a',
      title: 'Chapter 2',
      url: '/c2a',
      number: 2,
      scanlator: 'Alpha',
    ),
    Episode(
      id: 'c2b',
      title: 'Chapter 2',
      url: '/c2b',
      number: 2,
      scanlator: 'Beta',
    ),
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

class _FakeAuthCubit extends Cubit<AuthState> implements AuthCubit {
  _FakeAuthCubit() : super(const AuthState());

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
    sl.registerSingleton<AuthCubit>(_FakeAuthCubit());
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
    // Chapter downloads: the per-chapter download icon reads both on build.
    // The downloader is lazy because it needs the SourceRepository each test
    // registers for itself, after this setUp has run.
    await ChapterDownloadStore.init();
    sl.registerSingleton<ChapterDownloadStore>(ChapterDownloadStore());
    sl.registerLazySingleton<ChapterDownloader>(
      () =>
          ChapterDownloader(sl<SourceRepository>(), sl<ChapterDownloadStore>()),
    );
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

  for (final reading in [true, false]) {
    testWidgets(
      reading
          ? 'reading detail does not prepare a video player'
          : 'external player selection does not prepare mpv',
      (tester) async {
        final pool = _WarmupPool();
        sl.registerSingleton<MpvPlayerPool>(pool);
        if (!reading) {
          sl.unregister<PlaybackPrefs>();
          sl.registerSingleton<PlaybackPrefs>(
            _FakePlaybackPrefs(playerPackage: 'external.player'),
          );
        }
        final stub = _StubSourceRepository(
          reading ? _novelDetail : _animeDetail,
        );
        sl.registerSingleton<SourceRepository>(stub);
        sl.registerSingleton<CatalogueRepository>(stub);
        await tester.pumpWidget(
          MaterialApp(
            home: DetailScreen(item: reading ? _novelItem : _animeItem),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(pool.preparations, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('video preparation is deferred and freed when detail closes', (
    tester,
  ) async {
    final pool = _WarmupPool();
    sl.registerSingleton<MpvPlayerPool>(pool);
    final stub = _StubSourceRepository(_animeDetail);
    sl.registerSingleton<SourceRepository>(stub);
    sl.registerSingleton<CatalogueRepository>(stub);
    await tester.pumpWidget(
      const MaterialApp(home: DetailScreen(item: _animeItem)),
    );
    await tester.pump();
    expect(pool.preparations, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(pool.preparations, 1);
    await tester.pumpWidget(const SizedBox());
    expect(pool.clears, 1);
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
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());

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

      // No main Download button (that one resolves video sources), but each
      // chapter row does carry its own download icon.
      expect(find.text('Download'), findsNothing);
      expect(find.byIcon(Icons.file_download_outlined), findsWidgets);

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
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
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
    'Next 10 batch starts after the finished chapter using the resolved source',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final episodes = List.generate(
        15,
        (i) => Episode(
          id: 'bulk-${i + 1}',
          title: 'Chapter ${i + 1}',
          number: (i + 1).toDouble(),
          url: '/bulk-${i + 1}',
        ),
      );
      final item = MediaItem(
        id: _novelItem.id,
        title: _novelItem.title,
        url: _novelItem.url,
        type: ProviderType.novel,
        sourceId: 'catalogue-pseudo-source',
      );
      final detail = _novelDetail.copyWith(
        sourceId: 'resolved-reader-source',
        episodes: episodes,
      );

      sl.unregister<ReadStore>();
      sl.registerSingleton<ReadStore>(
        _SourceKeyedReadStore(
          sourceId: 'resolved-reader-source',
          showId: item.id,
          marks: {'bulk-3': (pos: 19, total: 20)},
        ),
      );
      sl.registerSingleton<SourceRepository>(_StubSourceRepository(detail));
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());

      await tester.pumpWidget(MaterialApp(home: DetailScreen(item: item)));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.bySemanticsLabel('Download chapters'));
      await tester.pumpAndSettle();

      expect(find.text('Next 10'), findsOneWidget);
      expect(find.text('4 – 13'), findsOneWidget);
    },
  );

  testWidgets(
    'reversing a partial chapter range preserves chapters and their reader index',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final chapters = List.generate(
        60,
        (i) => Episode(
          id: 'chapter-${i + 1}',
          title: 'Chapter ${i + 1}',
          url: '/chapter-${i + 1}',
          number: (i + 1).toDouble(),
        ),
      );
      final detail = _novelDetail.copyWith(episodes: chapters);
      sl.registerSingleton<SourceRepository>(_StubSourceRepository(detail));
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _novelItem)),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'detail initial layout');

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'reverse menu layout');
      await tester.tap(find.text('Reverse list'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'reversed list layout');

      // The selected normal range (chapters 1–50) remains the same set after
      // reversal, so chapter 50 is first and is still tappable.
      expect(find.textContaining('Chapter 50'), findsOneWidget);
      await tester.tap(find.textContaining('Chapter 50'));
      await tester.pumpAndSettle();

      final reader = tester.widget<NovelReaderScreen>(
        find.byType(NovelReaderScreen),
      );
      expect(reader.startIndex, 49); // original chapter 50, zero-based
    },
  );

  testWidgets(
    'classic streaming custom range changes only the current season selection',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final episodes = List.generate(
        12,
        (i) => Episode(
          id: 'stream-${i + 1}',
          title: 'Episode ${i + 1}',
          url: '/stream-${i + 1}',
          number: (i + 1).toDouble(),
        ),
      );
      final detail = _animeDetail.copyWith(episodes: episodes);
      final repository = _StubSourceRepository(detail);
      sl.registerSingleton<SourceRepository>(repository);
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _animeItem)),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Download E1'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Custom range'), findsOneWidget);
      await tester.tap(find.byTooltip('Custom range'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(find.text('Find episode'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Episode 5');
      await tester.pumpAndSettle();
      await tester.tap(find.text('E5 · Episode 5'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('End'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Episode 7');
      await tester.pumpAndSettle();
      await tester.tap(find.text('E7 · Episode 7'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download').last);
      await tester.pumpAndSettle();

      expect(find.text('3 of 12 episodes'), findsOneWidget);
      // Opening the custom picker doesn't resolve any new links or change
      // the already-selected quality/source.
      expect(repository.sourceCalls, ['/stream-1']);
    },
  );

  testWidgets('minimal streaming download keeps its existing From picker', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final episodes = List.generate(
      12,
      (i) => Episode(
        id: 'minimal-${i + 1}',
        title: 'Episode ${i + 1}',
        url: '/minimal-${i + 1}',
        number: (i + 1).toDouble(),
      ),
    );
    final detail = _animeDetail.copyWith(episodes: episodes);
    sl.unregister<PlaybackPrefs>();
    sl.registerSingleton<PlaybackPrefs>(
      _FakePlaybackPrefs(batchStyle: 'minimal'),
    );
    sl.registerSingleton<SourceRepository>(_StubSourceRepository(detail));
    sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());

    await tester.pumpWidget(
      const MaterialApp(home: DetailScreen(item: _animeItem)),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Download E1'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Custom range'), findsNothing);
    expect(find.text('From E1'), findsOneWidget);
  });

  testWidgets('single download keeps the original server-picker sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sl.registerSingleton<EpisodeMetadataService>(EpisodeMetadataService(Dio()));
    final sub = _animeDetail.copyWith(subCount: 2, dubCount: 2);
    final dub = sub.copyWith(
      episodes: const [
        Episode(id: 'd1', title: 'Dub 1', url: '/dub1', number: 1),
        Episode(id: 'd2', title: 'Dub 2', url: '/dub2', number: 2),
      ],
    );
    sl.registerSingleton<SourceRepository>(_DownloadRepository(sub, dub));
    sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
    final downloads = _RecordingDownloads();
    await sl.unregister<DownloadManager>();
    sl.registerSingleton<DownloadManager>(downloads);
    await tester.pumpWidget(
      const MaterialApp(home: DetailScreen(item: _animeItem)),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('Download episode').last);
    await tester.pumpAndSettle();
    expect(find.text('Download 1 episode'), findsNothing);
    await tester.tap(find.text('Mirror B').last);
    await tester.pumpAndSettle();
    expect(downloads.method, #enqueueSource);
    expect((downloads.arguments[#episode] as Episode).url, '/e2');
    expect(downloads.arguments[#category], 'sub');
    final chosen = downloads.arguments[#source] as VideoSource;
    expect(chosen.url, 'https://test/b.mp4');
    expect(chosen.headers?['Referer'], 'https://test/');
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'compact single picker switches only the selected episode to Dub',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      sl.registerSingleton<EpisodeMetadataService>(
        EpisodeMetadataService(Dio()),
      );
      final sub = _animeDetail.copyWith(subCount: 2, dubCount: 2);
      final dub = sub.copyWith(
        episodes: const [
          Episode(id: 'd1', title: 'Dub 1', url: '/dub1', number: 1),
          Episode(id: 'd2', title: 'Dub 2', url: '/dub2', number: 2),
        ],
      );
      sl.registerSingleton<SourceRepository>(_DownloadRepository(sub, dub));
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
      final downloads = _RecordingDownloads();
      await sl.unregister<DownloadManager>();
      sl.registerSingleton<DownloadManager>(downloads);
      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _animeItem)),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('Download episode').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dub').last);
      await tester.pumpAndSettle();
      expect(find.text('Download 1 episode'), findsNothing);
      await tester.tap(find.text('Mirror B').last);
      await tester.pumpAndSettle();
      expect(downloads.method, #enqueueSource);
      expect((downloads.arguments[#episode] as Episode).url, '/dub2');
      expect(downloads.arguments[#category], 'dub');
      expect(
        (downloads.arguments[#source] as VideoSource).url,
        'https://test/b.mp4',
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('compact single picker clears servers when Dub is unavailable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sl.registerSingleton<EpisodeMetadataService>(EpisodeMetadataService(Dio()));
    final sub = _animeDetail.copyWith(subCount: 2, dubCount: 2);
    final dub = sub.copyWith(
      episodes: const [
        Episode(id: 'd1', title: 'Dub 1', url: '/dub1', number: 1),
        Episode(id: 'd2', title: 'Dub 2', url: '/dub2', number: 2),
      ],
    );
    sl.registerSingleton<SourceRepository>(
      _DownloadRepository(sub, dub, failDub: true),
    );
    sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
    final downloads = _RecordingDownloads();
    await sl.unregister<DownloadManager>();
    sl.registerSingleton<DownloadManager>(downloads);
    await tester.pumpWidget(
      const MaterialApp(home: DetailScreen(item: _animeItem)),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('Download episode').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dub').last);
    await tester.pumpAndSettle();
    expect(find.text('Download 1 episode'), findsNothing);
    expect(find.text('Mirror B'), findsNothing);
    expect(downloads.method, isNull);
    await tester.tap(find.text('Sub').last);
    await tester.pumpAndSettle();
    expect(find.text('Mirror B'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'compact single picker never substitutes a different Dub episode',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      sl.registerSingleton<EpisodeMetadataService>(
        EpisodeMetadataService(Dio()),
      );
      final sub = _animeDetail.copyWith(subCount: 2, dubCount: 2);
      final dub = sub.copyWith(
        episodes: const [
          Episode(id: 'd1', title: 'Dub 1', url: '/dub1', number: 1),
          Episode(id: 'd2', title: 'Dub 2', url: '/dub2', number: 2),
        ],
      );
      sl.registerSingleton<SourceRepository>(
        _DownloadRepository(sub, dub.copyWith(episodes: [dub.episodes.first])),
      );
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
      final downloads = _RecordingDownloads();
      await sl.unregister<DownloadManager>();
      sl.registerSingleton<DownloadManager>(downloads);
      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _animeItem)),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byTooltip('Download episode').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dub').last);
      await tester.pumpAndSettle();
      expect(find.text('Download 1 episode'), findsNothing);
      expect(find.text('Mirror B'), findsNothing);
      expect(downloads.method, isNull);
      await tester.tap(find.text('Sub').last);
      await tester.pumpAndSettle();
      expect(find.text('Mirror B'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a failed language switch never keeps the old episode selected', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sl.registerSingleton<EpisodeMetadataService>(EpisodeMetadataService(Dio()));
    final detail = _animeDetail.copyWith(subCount: 2, dubCount: 2);
    sl.registerSingleton<SourceRepository>(
      _DownloadRepository(detail, detail, failDub: true),
    );
    sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
    await tester.pumpWidget(
      const MaterialApp(home: DetailScreen(item: _animeItem)),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Download E1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dub').last);
    await tester.pumpAndSettle();
    expect(find.text('No episodes to download'), findsOneWidget);
    expect(find.text('Download 1 episode'), findsNothing);
  });

  testWidgets(
    'Continue on a multi-group source opens the same group, not the same '
    'chapter again from another one',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      sl.registerSingleton<SourceRepository>(
        _StubSourceRepository(_multiGroupDetail),
      );
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
      // Alpha's chapter 1 is finished. The next ROW is Beta's chapter 1;
      // Continue has to skip it and open Alpha's chapter 2 (index 2).
      sl.unregister<ReadStore>();
      sl.registerSingleton<ReadStore>(
        _FakeReadStore({'c1a': (pos: 19, total: 20)}),
      );

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _novelItem)),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Continue').first);
      await tester.pumpAndSettle();

      final reader = tester.widget<NovelReaderScreen>(
        find.byType(NovelReaderScreen),
      );
      expect(reader.startIndex, 2);
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
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
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

  for (final playerPackage in ['', PlaybackPrefs.androidPlayerId]) {
    testWidgets('built-in player $playerPackage opens without a mirror sheet', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      sl.unregister<PlaybackPrefs>();
      sl.registerSingleton<PlaybackPrefs>(
        _FakePlaybackPrefs(playerPackage: playerPackage),
      );

      final sourceRepository = _StubSourceRepository(_animeDetail);
      sl.registerSingleton<SourceRepository>(sourceRepository);
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());

      final observer = _RecordingNavigatorObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: const DetailScreen(item: _animeItem),
        ),
      );
      await tester.pump(); // let the cubit's load() resolve
      // The detail prefetch starts after a 700ms stay-delay. Keep this check
      // just below that threshold: Play should still work before prefetch fires.
      await tester.pump(const Duration(milliseconds: 699));

      expect(find.text('Play'), findsWidgets);
      expect(find.text('Read'), findsNothing);
      expect(
        sourceRepository.prefetchCalls,
        isEmpty,
        reason: 'opening detail must not resolve links before Play is tapped',
      );

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
      expect(sourceRepository.sourceCalls, isEmpty);
    });
  }

  testWidgets('external app still asks for a mirror before launch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    sl.unregister<PlaybackPrefs>();
    sl.registerSingleton<PlaybackPrefs>(
      _FakePlaybackPrefs(playerPackage: 'external.player'),
    );
    final repository = _StubSourceRepository(_animeDetail);
    sl.registerSingleton<SourceRepository>(repository);
    sl.registerSingleton<CatalogueRepository>(repository);
    await tester.pumpWidget(
      const MaterialApp(home: DetailScreen(item: _animeItem)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 699));
    await tester.tap(find.text('Play').first);
    await tester.pumpAndSettle();
    expect(find.text('Play mirror'), findsOneWidget);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(repository.sourceCalls, hasLength(1));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Play mirror'), findsNothing);
    expect(find.byType(DetailScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());

      await tester.pumpWidget(
        const MaterialApp(home: DetailScreen(item: _novelItem)),
      );
      await tester.pump();
      await tester.pump();

      // One portrait cover per chapter, at the agreed size.
      expect(find.byKey(chapterCover), findsNWidgets(2));
      expect(
        tester.getSize(find.byKey(chapterCover).first),
        const Size(44, 62),
      );

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

  testWidgets('marking a chapter read writes the key the chapter list reads', (
    tester,
  ) async {
    // Reading state is keyed by item.id; video by item.url. Writing a
    // chapter under the video key stored it where nothing looks, so the
    // row stayed undimmed and the mark seemed not to take.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    sl.registerSingleton<SourceRepository>(
      _StubSourceRepository(novelWithDates(null)),
    );
    sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
    final store = _KeyedReadStore();
    sl.unregister<ReadStore>();
    sl.registerSingleton<ReadStore>(store);

    await tester.pumpWidget(
      const MaterialApp(home: DetailScreen(item: _novelItem)),
    );
    await tester.pump();
    await tester.pump();

    expect(store.readShowIds, isNotEmpty, reason: 'row read some key');
    final rowKey = store.readShowIds.first;

    await tester.longPress(find.byKey(chapterCover).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as read'));
    await tester.pumpAndSettle();

    expect(store.writtenShowIds, isNotEmpty, reason: 'the mark was written');
    expect(store.writtenShowIds.first, rowKey);

    // The confirmation toast sets a 2s timer; let it expire or the binding
    // fails the test for a pending timer after teardown.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('long-pressing a chapter opens the READING actions menu', (
    tester,
  ) async {
    // Chapters render as _ChapterRow, not _EpisodeRow. Wiring the menu into
    // the episode row alone left reading with no long-press at all — the
    // callback reached the tab and stopped one widget short of the leaf.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    sl.registerSingleton<SourceRepository>(
      _StubSourceRepository(novelWithDates(null)),
    );
    sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());

    await tester.pumpWidget(
      const MaterialApp(home: DetailScreen(item: _novelItem)),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(chapterCover).first);
    await tester.pumpAndSettle();

    expect(find.text('Mark as read'), findsOneWidget);
    expect(find.text('Mark this and all above as read'), findsOneWidget);
    // Those two rows and nothing else — everything above them is playback.
    expect(find.text('Play with…'), findsNothing);
    expect(find.text('Play mirror'), findsNothing);
    expect(find.text('Reload links'), findsNothing);
    expect(find.text('Where to watch'), findsNothing);
    expect(find.text('Where to read'), findsNothing);
    expect(find.text('Mark as watched'), findsNothing);
  });

  testWidgets(
    'the chapter row drops its meta line when the source has no date',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      sl.registerSingleton<SourceRepository>(
        _StubSourceRepository(novelWithDates(null)),
      );
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());

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
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
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
      sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());

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
