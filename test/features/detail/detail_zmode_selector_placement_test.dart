// Task 18 Part B: MatchLine moved from below the synopsis into the actions
// column, right under Play/Download. Harness mirrors
// reading_detail_routing_test.dart's lightweight GetIt stubs (no Hive boxes
// beyond MatchStore/ReaderPrefs, no platform channels) and pumps the PHONE
// DetailScreen directly.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:video_player/video_player.dart' as preview;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:watch_app/core/ui/route_observer.dart';
import 'package:watch_app/features/player/player_lifecycle.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/download/chapter_downloader.dart';
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
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/trailer/trailer_service.dart';
import 'package:watch_app/core/zmode/match_store.dart';
import 'package:watch_app/core/zmode/zmode_source_prefs.dart';
import 'package:watch_app/core/zmode/source_matcher.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/features/detail/detail_screen.dart';
import 'package:watch_app/features/detail/wrong_title_sheet.dart';

class _PreviewPlatform extends VideoPlayerPlatform {
  final streams = <int, StreamController<VideoEvent>>{};
  final calls = <String>[];
  Duration position = Duration.zero;
  Completer<void>? disposeGate;
  final disposed = Completer<void>();
  bool fail = false;
  bool failFirst = false;
  bool deferInitialization = false;
  bool deferFirstInitialization = false;

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = streams.length;
    final events = streams[id] = StreamController<VideoEvent>();
    calls.add('create');
    if (fail || (failFirst && id == 0)) {
      events.addError(
        PlatformException(code: 'VideoError', message: 'Test preview error'),
      );
    } else if (!deferInitialization && !(deferFirstInitialization && id == 0)) {
      events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          size: const Size(640, 360),
          duration: const Duration(seconds: 30),
        ),
      );
    }
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId]!.stream;
  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    if (!disposed.isCompleted) disposed.complete();
    final gate = disposeGate;
    if (gate != null) await gate.future;
    unawaited(streams[playerId]!.close());
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause');
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {
    calls.add('volume:$volume');
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    calls.add('loop:$looping');
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<Duration> getPosition(int playerId) async => position;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
}

// ── Minimal stubs — same shapes as reading_detail_routing_test.dart ────────

class _StubSourceRepository implements SourceRepository {
  _StubSourceRepository(
    this._detail, {
    this.sourceList = const [],
    this.detailGate,
    this.searchStartedBySource,
    this.searchGates,
  });
  final MediaDetail _detail;
  final List<({String id, String name})> sourceList;
  final Completer<void>? detailGate;
  final Map<String, Completer<void>>? searchStartedBySource;
  final Map<String, Completer<List<MediaItem>>>? searchGates;
  final searchQueries = <String>[];
  final searchedSources = <String?>[];

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
    bool Function()? abandoned,
  }) async {
    if (detailGate != null) await detailGate!.future;
    onPartial?.call(_detail);
    return _detail;
  }

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) async {
    searchQueries.add(query);
    searchedSources.add(sourceId);
    final started = searchStartedBySource?[sourceId];
    if (started != null && !started.isCompleted) {
      started.complete();
    }
    return await searchGates?[sourceId]?.future ?? const [];
  }

  @override
  void prefetch(String url, {String? sourceId}) {}

  @override
  String get sourceId => 'test';

  @override
  bool hasSource(String id) => sourceList.any((source) => source.id == id);

  @override
  String displayName(String id) => id;

  @override
  List<({String id, String name})> get loadedSources => sourceList;

  @override
  String baseUrlFor(String sourceId) => 'https://example.test';
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

class _FakeTrailerService extends TrailerService {
  _FakeTrailerService({this.result}) : super(Dio());

  @override
  Future<({String video, String audio})?> streamUrlHd(String youtubeId) async =>
      (
        video: 'https://example.test/hd.mp4',
        audio: 'https://example.test/audio.m4a',
      );

  final Future<String?>? result;
  int streamCalls = 0;

  @override
  Future<String?> streamUrl(String youtubeId, {bool low = false}) async {
    streamCalls++;
    return 'https://example.test/trailer.mp4';
  }

  @override
  Future<String?> youtubeId({
    required String title,
    String? englishTitle,
    required ProviderType type,
    String? year,
  }) async => result;
}

class _FakePlaybackPrefs extends PlaybackPrefs {
  _FakePlaybackPrefs({this.hd = false});
  final bool hd;
  @override
  bool get autoplayTrailer => true;

  @override
  bool get trailerHd => hd;

  @override
  bool get autoAddToMyList => false;

  @override
  String get defaultCategory => 'sub';
}

// ── Test data ────────────────────────────────────────────────────────────

// sourceId is deliberately left as the plain stub id, not ZmodeIds.sourceId
// ('zm') — the Part B gate this suite exercises is purely URL-based
// (ZmodeIds.isZ reads widget.item.url), and a real 'zm' sourceId would also
// route the Details-tab source label through MetadataRepository, which this
// lightweight harness has no need to register.
const _zmItem = MediaItem(
  id: 'zm-anime',
  title: 'Z Mode Anime',
  url: 'zm://anime/mal:5114',
  type: ProviderType.anime,
  sourceId: 'test',
);

const _zmDetail = MediaDetail(
  id: 'zm-anime',
  title: 'Z Mode Anime',
  url: 'zm://anime/mal:5114',
  type: ProviderType.anime,
  sourceId: 'test',
  // No malId — a non-null one drives _ensureFiller into a real Jikan
  // network call (FillerService.instance is a hardcoded singleton, not
  // injectable here), which never resolves inside a widget test's pump.
  description: 'A synopsis long enough to render its own section.',
  episodes: [Episode(id: 'e1', title: 'Episode 1', url: '/e1', number: 1)],
);

const _plainItem = MediaItem(
  id: 'test-anime',
  title: 'Test Anime',
  url: 'http://test/anime',
  type: ProviderType.anime,
  sourceId: 'test',
);

const _plainDetail = MediaDetail(
  id: 'test-anime',
  title: 'Test Anime',
  url: 'http://test/anime',
  type: ProviderType.anime,
  sourceId: 'test',
  description: 'A synopsis long enough to render its own section.',
  episodes: [Episode(id: 'e1', title: 'Episode 1', url: '/e1', number: 1)],
);

void main() {
  late ZSourcePrefs prefs;
  late Directory tempDir;
  late _PreviewPlatform previewPlatform;

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
    previewPlatform = _PreviewPlatform();
    VideoPlayerPlatform.instance = previewPlatform;
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

    tempDir = await Directory.systemTemp.createTemp('detail_zmode_test');
    Hive.init(tempDir.path);
    await ReaderPrefs.init();
    sl.registerSingleton<ReaderPrefs>(ReaderPrefs());
    await ChapterDownloadStore.init();
    sl.registerSingleton<ChapterDownloadStore>(ChapterDownloadStore());
    sl.registerLazySingleton<ChapterDownloader>(
      () =>
          ChapterDownloader(sl<SourceRepository>(), sl<ChapterDownloadStore>()),
    );
    sl.registerSingleton<ReadStore>(_FakeReadStore());
    sl.registerSingleton<ReadHistory>(
      ReadHistory(SupabaseService(), () => null),
    );
    sl.registerSingleton<WatchHistory>(
      WatchHistory(SupabaseService(), () => null),
    );

    // MatchLine's own dependencies — the source list is empty, so it settles
    // straight into the "no source" state without any async matcher work.
    final matchStore = await MatchStore.open();
    prefs = await ZSourcePrefs.open();
    sl.registerSingleton<MatchStore>(matchStore);
    sl.registerSingleton<ZSourcePrefs>(prefs);
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await sl.reset();
    await Hive.deleteFromDisk();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> drainPreviewTeardown(WidgetTester tester) async {
    var idle = false;
    final waiting = playerRouteTeardownBarrier.waitUntilIdle().then(
      (_) => idle = true,
    );
    for (var i = 0; i < 20 && !idle; i++) {
      await tester.pump();
      await tester.runAsync(() async {});
    }
    expect(
      idle,
      isTrue,
      reason: 'Preview disposal must release the playback barrier',
    );
    await waiting;
  }

  Future<void> pumpDetail(
    WidgetTester tester,
    MediaItem item,
    MediaDetail detail, {
    _StubSourceRepository? source,
    bool entering = false,
  }) async {
    final stub = source ?? _StubSourceRepository(detail);
    sl.registerSingleton<SourceRepository>(stub);
    sl.registerSingleton<CatalogueRepository>(sl<SourceRepository>());
    sl.registerSingleton<SourceMatcher>(
      SourceMatcher(
        sources: stub,
        store: sl<MatchStore>(),
        prefs: sl<ZSourcePrefs>(),
        candidates: (_) => stub.loadedSources,
      ),
    );

    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [appRouteObserver],
        home: entering
            ? Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                    PageRouteBuilder<void>(
                      transitionDuration: const Duration(seconds: 1),
                      pageBuilder: (_, _, _) => DetailScreen(item: item),
                    ),
                  ),
                  child: const Text('Open detail'),
                ),
              )
            : DetailScreen(item: item),
      ),
    );
    if (entering) {
      await tester.tap(find.text('Open detail'));
      await tester.pump();
    }
    await tester.pump(); // let the cubit's load() resolve
    await tester.pump(); // MatchLine's own build-time resolve, if any
  }

  testWidgets('movie detail keeps a list row without episode wording', (
    tester,
  ) async {
    await pumpDetail(
      tester,
      _plainItem,
      _plainDetail.copyWith(
        title: 'Film title',
        format: 'MOVIE',
        durationMins: 110,
      ),
    );
    expect(find.text('Film title'), findsWidgets);
    expect(find.text('Movie'), findsOneWidget);
    expect(find.text('Movie · 1h 50m'), findsOneWidget);
    expect(find.text('1 Episode'), findsNothing);
    expect(find.text('Episode 1'), findsNothing);
    final row = find.ancestor(
      of: find.text('Film title').last,
      matching: find.byType(InkWell),
    );
    expect(row, findsWidgets);
    expect(tester.widget<InkWell>(row.first).onTap, isNotNull);
  });

  testWidgets('trailer lookup updates only the hero during entry', (
    tester,
  ) async {
    final trailer = Completer<String?>();
    await sl.unregister<TrailerService>();
    final service = _FakeTrailerService(result: trailer.future);
    sl.registerSingleton<TrailerService>(service);
    await pumpDetail(tester, _plainItem, _plainDetail, entering: true);
    final title = tester.widget<Text>(find.text('Test Anime').last);
    trailer.complete('test-trailer');
    await tester.pump();
    expect(tester.widget<Text>(find.text('Test Anime').last), same(title));
    expect(tester.takeException(), isNull);
    expect(service.streamCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'trailer uses a muted looping native preview and waits for progress',
    (tester) async {
      await sl.unregister<TrailerService>();
      sl.registerSingleton<TrailerService>(
        _FakeTrailerService(result: Future.value('trailer')),
      );
      await pumpDetail(tester, _plainItem, _plainDetail);
      await tester.pump();
      await tester.pump();
      expect(previewPlatform.calls, contains('create'));
      expect(previewPlatform.calls, contains('volume:0.0'));
      expect(previewPlatform.calls, contains('loop:true'));
      expect(previewPlatform.calls, contains('play'));
      final fade = find
          .ancestor(
            of: find.byType(preview.VideoPlayer),
            matching: find.byType(AnimatedOpacity),
          )
          .first;
      expect(tester.widget<AnimatedOpacity>(fade).opacity, 0);
      previewPlatform.position = const Duration(milliseconds: 100);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<AnimatedOpacity>(fade).opacity, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(
        () =>
            previewPlatform.disposed.future.timeout(const Duration(seconds: 2)),
      );
      expect(previewPlatform.calls, contains('dispose'));
      await drainPreviewTeardown(tester);
    },
  );

  testWidgets(
    'trailer releases on cover and restores without overriding pause',
    (tester) async {
      await sl.unregister<TrailerService>();
      sl.registerSingleton<TrailerService>(
        _FakeTrailerService(result: Future.value('trailer')),
      );
      await pumpDetail(tester, _plainItem, _plainDetail);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byIcon(Icons.pause_rounded));
      await tester.pump();
      final plays = previewPlatform.calls.where((c) => c == 'play').length;
      final nav = Navigator.of(tester.element(find.byType(DetailScreen)));
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covered')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () =>
            previewPlatform.disposed.future.timeout(const Duration(seconds: 2)),
      );
      expect(previewPlatform.calls, contains('dispose'));
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(previewPlatform.calls.where((c) => c == 'create'), hasLength(2));
      expect(previewPlatform.calls.where((c) => c == 'play'), hasLength(plays));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await drainPreviewTeardown(tester);
    },
  );

  testWidgets(
    'leaving during trailer initialization disposes without waiting for media',
    (tester) async {
      previewPlatform.deferInitialization = true;
      await sl.unregister<TrailerService>();
      sl.registerSingleton<TrailerService>(
        _FakeTrailerService(result: Future.value('trailer')),
      );
      await pumpDetail(tester, _plainItem, _plainDetail);
      await tester.pump();
      final nav = Navigator.of(tester.element(find.byType(DetailScreen)));
      unawaited(
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covered')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.runAsync(
        () =>
            previewPlatform.disposed.future.timeout(const Duration(seconds: 2)),
      );
      expect(previewPlatform.calls, contains('dispose'));
      expect(previewPlatform.calls, isNot(contains('play')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await drainPreviewTeardown(tester);
    },
  );

  testWidgets('failed trailer keeps artwork and releases its controller', (
    tester,
  ) async {
    previewPlatform.fail = true;
    await sl.unregister<TrailerService>();
    sl.registerSingleton<TrailerService>(
      _FakeTrailerService(result: Future.value('trailer')),
    );
    await pumpDetail(tester, _plainItem, _plainDetail);
    await tester.pump();
    expect(find.byType(preview.VideoPlayer), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(
      () => previewPlatform.disposed.future.timeout(const Duration(seconds: 2)),
    );
    expect(previewPlatform.calls, contains('dispose'));
    await drainPreviewTeardown(tester);
  });

  testWidgets('HD preview failure falls back to the standard stream', (
    tester,
  ) async {
    previewPlatform.failFirst = true;
    await sl.unregister<PlaybackPrefs>();
    sl.registerSingleton<PlaybackPrefs>(_FakePlaybackPrefs(hd: true));
    await sl.unregister<TrailerService>();
    final service = _FakeTrailerService(result: Future.value('trailer'));
    sl.registerSingleton<TrailerService>(service);
    await pumpDetail(tester, _plainItem, _plainDetail);
    await tester.pump();
    await tester.runAsync(
      () => previewPlatform.disposed.future.timeout(const Duration(seconds: 2)),
    );
    await tester.pump();
    await tester.pump();
    expect(service.streamCalls, 1);
    expect(previewPlatform.calls.where((c) => c == 'create'), hasLength(2));
    expect(previewPlatform.calls, contains('play'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await drainPreviewTeardown(tester);
  });

  testWidgets('HD preparation timeout falls back to the standard stream', (
    tester,
  ) async {
    previewPlatform.deferFirstInitialization = true;
    await sl.unregister<PlaybackPrefs>();
    sl.registerSingleton<PlaybackPrefs>(_FakePlaybackPrefs(hd: true));
    await sl.unregister<TrailerService>();
    final service = _FakeTrailerService(result: Future.value('trailer'));
    sl.registerSingleton<TrailerService>(service);
    await pumpDetail(tester, _plainItem, _plainDetail);
    await tester.pump();
    expect(previewPlatform.calls.where((c) => c == 'create'), hasLength(1));
    await tester.pump(const Duration(seconds: 8));
    await tester.runAsync(
      () => previewPlatform.disposed.future.timeout(const Duration(seconds: 2)),
    );
    await tester.pump();
    await tester.pump();
    expect(service.streamCalls, 1);
    expect(previewPlatform.calls.where((c) => c == 'create'), hasLength(2));
    expect(previewPlatform.calls, contains('play'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await drainPreviewTeardown(tester);
  });

  testWidgets('replacement playback waits until the native preview releases', (
    tester,
  ) async {
    final released = previewPlatform.disposeGate = Completer<void>();
    await sl.unregister<TrailerService>();
    sl.registerSingleton<TrailerService>(
      _FakeTrailerService(result: Future.value('trailer')),
    );
    await pumpDetail(tester, _plainItem, _plainDetail);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(
      () => previewPlatform.disposed.future.timeout(const Duration(seconds: 2)),
    );
    var replacementReady = false;
    final waiting = playerRouteTeardownBarrier.waitUntilIdle().then(
      (_) => replacementReady = true,
    );
    await tester.pump();
    expect(replacementReady, isFalse);
    released.complete();
    await drainPreviewTeardown(tester);
    await waiting;
    expect(replacementReady, isTrue);
  });

  testWidgets('a late trailer lookup does not start after leaving detail', (
    tester,
  ) async {
    final trailer = Completer<String?>();
    final service = _FakeTrailerService(result: trailer.future);
    await sl.unregister<TrailerService>();
    sl.registerSingleton<TrailerService>(service);
    await pumpDetail(tester, _plainItem, _plainDetail, entering: true);
    await tester.pumpWidget(const SizedBox.shrink());
    trailer.complete('late-trailer');
    await tester.pump();
    expect(service.streamCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a zm:// item shows the selector under the action buttons, above the synopsis',
    (tester) async {
      await pumpDetail(tester, _zmItem, _zmDetail);

      expect(find.byType(MatchLine), findsOneWidget);

      final matchY = tester.getTopLeft(find.byType(MatchLine)).dy;
      final downloadY = tester
          .getTopLeft(find.byIcon(Icons.file_download_outlined).first)
          .dy;
      final synopsisY = tester
          .getTopLeft(find.textContaining('A synopsis long enough'))
          .dy;

      // Sits right after the buttons (below Download) and before the synopsis
      // section that follows it — the old placement (section 4.5) was AFTER
      // the synopsis instead.
      expect(matchY, greaterThan(downloadY));
      expect(matchY, lessThan(synopsisY));
    },
  );

  testWidgets('Auto Resolve can stop searching and keeps no late match', (
    tester,
  ) async {
    const sources = [
      (id: 'first', name: 'First'),
      (id: 'second', name: 'Second'),
    ];
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstGate = Completer<List<MediaItem>>();
    final secondGate = Completer<List<MediaItem>>();
    final source = _StubSourceRepository(
      _zmDetail,
      sourceList: sources,
      searchStartedBySource: {'first': firstStarted, 'second': secondStarted},
      searchGates: {'first': firstGate, 'second': secondGate},
    );

    await pumpDetail(tester, _zmItem, _zmDetail, source: source);
    await firstStarted.future;
    await tester.pump();

    expect(find.text('Auto Resolve · First · 1/2'), findsOneWidget);
    final stop = find.byKey(const ValueKey('stop-auto-resolve'));
    expect(stop, findsOneWidget);

    firstGate.complete(const []);
    await secondStarted.future;
    await tester.pump();
    expect(find.text('Auto Resolve · Second · 2/2'), findsOneWidget);

    await tester.tap(stop);
    await tester.pump();
    expect(find.byKey(const ValueKey('stop-auto-resolve')), findsNothing);
    expect(find.text('Auto Resolve'), findsOneWidget);

    secondGate.complete([
      MediaItem(
        id: 'late',
        title: _zmDetail.title,
        url: 'https://second/show',
        type: ProviderType.anime,
        sourceId: 'second',
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(source.searchedSources, ['first', 'second']);
    expect(
      sl<MatchStore>().get(const ZCanonical(ZKind.anime, 'mal:5114'), 'first'),
      isNull,
    );
    expect(
      sl<MatchStore>().get(const ZCanonical(ZKind.anime, 'mal:5114'), 'second'),
      isNull,
    );
  });

  testWidgets('a normal source item never shows the selector', (tester) async {
    await pumpDetail(tester, _plainItem, _plainDetail);

    expect(find.byType(MatchLine), findsNothing);
  });

  testWidgets('waits for full metadata before auto-matching a Z Mode title', (
    tester,
  ) async {
    final detailGate = Completer<void>();
    const alias = 'The Former Supreme';
    const mangaItem = MediaItem(
      id: 'former-supreme',
      title: 'Jeonjikjijon',
      url: 'zm://manga/mal:5114',
      type: ProviderType.manga,
      sourceId: 'test',
    );
    final source = _StubSourceRepository(
      const MediaDetail(
        id: 'former-supreme',
        title: 'Jeonjikjijon',
        url: 'zm://manga/mal:5114',
        type: ProviderType.manga,
        sourceId: 'zm',
        synonyms: [alias],
      ),
      sourceList: const [(id: 'mihon:test', name: 'Test Source')],
      detailGate: detailGate,
    );

    await pumpDetail(tester, mangaItem, source._detail, source: source);

    // The tapped card has no synonyms yet. Searching at this point races the
    // catalogue lookup and prevents its alias-aware result from being reused.
    expect(find.byType(MatchLine), findsNothing);
    expect(source.searchQueries, isEmpty);

    detailGate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byType(MatchLine), findsOneWidget);
    expect(source.searchQueries, ['Jeonjikjijon', alias]);
  });
}

/// Empty [ReadStore] — the detail screen's resume-index lookup needs one
/// registered even though this suite only ever pumps anime (non-reading)
/// items.
class _FakeReadStore extends ReadStore {
  @override
  ({int pos, int total})? get(
    String sourceId,
    String showId,
    String chapterId,
  ) => null;

  @override
  bool finished(String sourceId, String showId, String chapterId) => false;
}
