import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/page_content.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/privacy/incognito_mode.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/reading_provider.dart';
import 'package:watch_app/core/reading/read_history.dart';
import 'package:watch_app/core/reading/read_store.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/reading/reader_settings.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/features/reader/manga_reader_screen.dart';

// ── Pure-logic tests ────────────────────────────────────────────────────────

void _pureLogicTests() {
  group('zoneFor', () {
    test('ltr: left third is previous, right third is next', () {
      expect(zoneFor(10, 300, 'ltr'), ReaderTapZone.previous);
      expect(zoneFor(290, 300, 'ltr'), ReaderTapZone.next);
    });

    test('rtl: swaps previous/next', () {
      expect(zoneFor(10, 300, 'rtl'), ReaderTapZone.next);
      expect(zoneFor(290, 300, 'rtl'), ReaderTapZone.previous);
    });

    test('center third is chrome in both directions', () {
      expect(zoneFor(150, 300, 'ltr'), ReaderTapZone.chrome);
      expect(zoneFor(150, 300, 'rtl'), ReaderTapZone.chrome);
    });

    test('vertical: every dx is chrome — no left/right paging', () {
      expect(zoneFor(10, 300, 'vertical'), ReaderTapZone.chrome);
      expect(zoneFor(150, 300, 'vertical'), ReaderTapZone.chrome);
      expect(zoneFor(290, 300, 'vertical'), ReaderTapZone.chrome);
    });
  });

  group('preloadWindow', () {
    test('returns the next 3 indices', () {
      expect(preloadWindow(0, 10), [1, 2, 3]);
      expect(preloadWindow(5, 10), [6, 7, 8]);
    });

    test('clamps to the end of the chapter', () {
      expect(preloadWindow(8, 10), [9]);
      expect(preloadWindow(9, 10), <int>[]);
    });

    test('empty chapter yields nothing', () {
      expect(preloadWindow(0, 0), <int>[]);
    });
  });

  group('clampPageIndex', () {
    test('in-range index passes through', () {
      expect(clampPageIndex(3, 10), 3);
    });

    test('negative clamps to 0', () {
      expect(clampPageIndex(-1, 10), 0);
    });

    test('out-of-range clamps to the last page', () {
      expect(clampPageIndex(99, 10), 9);
    });

    test('an empty/unknown chapter clamps to 0', () {
      expect(clampPageIndex(5, 0), 0);
    });
  });

  group('estimateIndexFromScroll', () {
    test('top of scroll is page 0, bottom is the last page', () {
      expect(estimateIndexFromScroll(0, 1000, 5), 0);
      expect(estimateIndexFromScroll(1000, 1000, 5), 4);
    });

    test('midway scroll lands near the middle page', () {
      expect(estimateIndexFromScroll(500, 1000, 5), 2);
    });

    test(
      'a chapter that fits on screen (no scroll extent) is the last page',
      () {
        expect(estimateIndexFromScroll(0, 0, 5), 4);
      },
    );

    test('empty chapter is page 0', () {
      expect(estimateIndexFromScroll(0, 1000, 0), 0);
    });
  });
}

// ── Widget-level fakes ───────────────────────────────────────────────────────

/// A fake reading-capable source that hands back canned pages per chapter
/// URL — mirrors `_FakeReadingProvider` in novel_reader_test.dart, with
/// `getPages` implemented instead of `getText`.
class _FakeReadingProvider implements BaseProvider, ReadingProvider {
  _FakeReadingProvider(this.sourceId, this.pagesByUrl, {this.episodes});

  @override
  final String sourceId;
  final Map<String, List<PageImage>> pagesByUrl;

  /// Full chapter list for `getEpisodes` — the `resolveChapters` upgrade
  /// test is the only one that sets this. Every other test leaves it null,
  /// so `getEpisodes` stays unreachable (`UnimplementedError`), same as
  /// before this field existed.
  final List<Episode>? episodes;

  @override
  String get displayName => sourceId;

  @override
  Future<ProviderInfo> getInfo() => throw UnimplementedError();

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) => throw UnimplementedError();

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) => throw UnimplementedError();

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) {
    final eps = episodes;
    if (eps == null) throw UnimplementedError();
    return Future.value(eps);
  }

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) => throw UnimplementedError();

  @override
  Future<List<PageImage>> getPages(String chapterUrl) async =>
      pagesByUrl[chapterUrl] ?? const [];

  @override
  Future<ChapterText> getText(String chapterUrl) => throw UnimplementedError();
}

/// A reading source whose `getPages` throws on the first call and succeeds
/// on every call after — for the error/retry path.
class _FlakyReadingProvider implements BaseProvider, ReadingProvider {
  _FlakyReadingProvider(this.sourceId, this.pages);

  @override
  final String sourceId;
  final List<PageImage> pages;
  int calls = 0;

  @override
  String get displayName => sourceId;

  @override
  Future<ProviderInfo> getInfo() => throw UnimplementedError();

  @override
  Future<List<HomeSection>?> getHome({String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) => throw UnimplementedError();

  @override
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  }) => throw UnimplementedError();

  @override
  Future<MediaDetail> getDetail(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'}) =>
      throw UnimplementedError();

  @override
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  }) => throw UnimplementedError();

  @override
  Future<List<PageImage>> getPages(String chapterUrl) async {
    calls++;
    if (calls == 1) throw Exception('network blip');
    return pages;
  }

  @override
  Future<ChapterText> getText(String chapterUrl) => throw UnimplementedError();
}

/// Records every `flush` value passed to [ReadHistory.save] (synchronously,
/// before delegating to the real implementation) so the carry-forward
/// requirement — flush on chapter change + on dispose — is provable without
/// reaching into private reader state. Same shape as novel_reader_test.dart's
/// spy.
class _SpyReadHistory extends ReadHistory {
  _SpyReadHistory(super.service, super.currentUserId);

  final List<bool> flushCalls = [];

  @override
  Future<void> save(ReadEntry e, {bool flush = false}) {
    flushCalls.add(flush);
    return super.save(e, flush: flush);
  }
}

Episode chapter(String id, String url, {double? number}) =>
    Episode(id: id, title: id, url: url, number: number);

/// Records every [Tracker.scrobble] call — no network, everything else is a
/// no-op. Mirrors media_kind_test.dart's `_FakeTracker`.
class _FakeTracker extends ChangeNotifier implements Tracker {
  @override
  bool get supportsReading => true;

  int scrobbleCalls = 0;
  MediaKind? lastScrobbleKind;
  int? lastScrobbleEpisode;
  int? lastScrobbleMalId;
  bool? lastScrobbleNovel;

  @override
  String get displayName => 'Fake';
  @override
  bool get isConnected => true;
  @override
  String? get viewerName => 'someone';
  @override
  String? get viewerAvatar => null;
  @override
  bool get autoSync => true;
  @override
  set autoSync(bool value) {}

  @override
  Future<bool> connect() async => true;
  @override
  Future<void> disconnect() async {}

  @override
  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    scrobbleCalls++;
    lastScrobbleKind = kind;
    lastScrobbleEpisode = episode;
    lastScrobbleMalId = malId;
    lastScrobbleNovel = novel;
  }

  @override
  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<List<TrackerListItem>> fetchList() async => const [];

  @override
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async => null;

  @override
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    String? pinnedId,
    WatchStatus? status,
    double? score,
    int? progress,
    MediaKind kind = MediaKind.anime,
  }) async {}

  @override
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async => const [];

  @override
  Map<String, dynamic>? exportSession() => null;
  @override
  Future<void> importSession(Map<String, dynamic> session) async {}
}

List<PageImage> pages(int count, {String prefix = 'https://example.com/p'}) =>
    List.generate(count, (i) => PageImage(url: '$prefix$i.jpg'));

/// Pumps a bounded, small number of frames instead of `pumpAndSettle()`.
///
/// Not `pumpAndSettle()` because every page's loading placeholder used to be
/// an indeterminate `CircularProgressIndicator`, which — against an
/// unreachable fake URL in this network-less sandbox — animates forever and
/// never lets `pumpAndSettle()` see "no more frames scheduled". The
/// placeholders are now static (`ColoredBox`, matching
/// poster_card.dart/continue_card.dart's convention), so this is moot, but
/// bounded pumping is kept regardless — it's simpler to reason about than
/// "settle, but only sometimes."
///
/// Pumps past `kDoubleTapTimeout` (~300ms): every page's GestureDetector
/// registers both `onTapUp` (tap zones) and `onDoubleTap` (zoom), so Flutter
/// delays resolving a single tap until it's sure a second tap isn't coming.
/// A shorter pump budget would assert before that single tap ever fires.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Whether [url] is registered (pending/live/keepAlive) in Flutter's global
/// image cache — proves `precacheImage`/`CachedNetworkImage` actually
/// touched it, without needing the real fetch to complete (unreachable in
/// this sandbox). `precacheImage` → `ImageProvider.resolve` →
/// `ImageCache.putIfAbsent` runs synchronously, so no extra pump is needed
/// between triggering it and checking here.
///
/// [width] must be the same `readerDecodeWidth` result the reader itself
/// computed (via [_decodeWidthFor]), since the on-screen page resolves
/// through a `ResizeImage`-wrapped, `maxWidth`-bounded provider — a
/// different cache key from a bare `CachedNetworkImageProvider(url)`.
///
/// Preloading no longer shows up here at all: it warms the disk cache
/// rather than decoding into memory, so these checks are now about what
/// should be *absent* from the image cache.
Future<bool> _imageTracked(String url, int width) async {
  final key = await ResizeImage.resizeIfNeeded(
    width,
    null,
    CachedNetworkImageProvider(url, maxWidth: width),
  ).obtainKey(ImageConfiguration.empty);
  return PaintingBinding.instance.imageCache.statusForKey(key).tracked;
}

/// The decode width the reader itself would compute for the current test
/// surface — mirrors `_MangaReaderScreenState._decodeWidth` exactly so
/// `_imageTracked` checks the real cache key instead of a guessed one.
int _decodeWidthFor(WidgetTester tester) {
  final mq = MediaQuery.of(tester.element(find.byType(MangaReaderScreen)));
  return readerDecodeWidth((mq.size.width * mq.devicePixelRatio).round());
}

/// The scale currently applied to the webtoon strip — read straight off the
/// `Transform` that wraps the vertical `ListView` (the same one both the
/// broken `InteractiveViewer` and the fixed `RawGestureDetector` produce), so
/// the pinch test asserts the real rendered scale in either structure.
double _webtoonScale(WidgetTester tester) {
  final t = tester
      .widgetList<Transform>(
        find.ancestor(
          of: find.byKey(const ValueKey('manga-listview')),
          matching: find.byType(Transform),
        ),
      )
      .first;
  return t.transform.getMaxScaleOnAxis();
}

/// A real two-pointer pinch driven by two `TestGesture`s. It starts with a
/// small *common* downward drift (both fingers together — a pure translation,
/// no change in span) and only then spreads the fingers apart.
///
/// That opening drift is deliberate and is what makes this a faithful repro
/// of the on-device bug: a Scrollable's vertical-drag recognizer greedily
/// claims that net downward motion and wins the gesture arena, after which a
/// scale recognizer sitting *above* the ListView (the old
/// InteractiveViewer) never gets the pinch. Real fingers never spread with a
/// perfectly cancelling net motion, so on a device the strip refused to zoom;
/// a symmetric-only spread hides the bug because the net drag is zero.
Future<void> _pinchOpen(WidgetTester tester) async {
  final center = tester.getCenter(
    find.byKey(const ValueKey('manga-listview')),
  );
  final f1 = await tester.startGesture(center - const Offset(0, 40), pointer: 1);
  final f2 = await tester.startGesture(center + const Offset(0, 40), pointer: 2);
  await tester.pump();
  // Phase 1: both fingers drift down together (net vertical drag, span held).
  for (var i = 0; i < 3; i++) {
    await f1.moveBy(const Offset(0, 10));
    await f2.moveBy(const Offset(0, 10));
    await tester.pump();
  }
  // Phase 2: spread apart (span grows -> a pinch).
  for (var i = 0; i < 8; i++) {
    await f1.moveBy(const Offset(0, -16));
    await f2.moveBy(const Offset(0, 16));
    await tester.pump();
  }
  await f1.up();
  await f2.up();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _pureLogicTests();

  group('MangaReaderScreen', () {
    late Directory dir;
    late _SpyReadHistory spyHistory;
    late AniyomiManager ani;

    // flutter_cache_manager's cache-info repo (sqflite-backed on macOS/iOS/
    // Android) throws `StateError: databaseFactory not initialized` the
    // first time *any* CachedNetworkImage in this whole test process ever
    // resolves — `flutter test` never registers a sqflite plugin, and
    // there's no first-party way to fake `databaseFactory` without a new
    // dependency. The failure is one-time only: flutter_cache_manager
    // doesn't retry its metadata-store lookup after the first failure, so
    // every image after this one silently falls straight through to a
    // network fetch instead. Absorbing that failure here — before any real
    // test runs, and with no widget/BuildContext needed, since
    // ImageProvider.resolve() doesn't require one — means whichever test
    // happens to run first doesn't pay for it. Unlike a first-position
    // `testWidgets`, `setUpAll` runs once for the group regardless of
    // `--name` filtering, so this doesn't create an ordering dependency the
    // way an explicit warm-up test would.
    setUpAll(() async {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => '/tmp',
          );
      final completer = Completer<void>();
      // runZonedGuarded, not a plain try/catch: the databaseFactory
      // StateError is thrown from deep inside flutter_cache_manager's own
      // detached stream-subscription chain, not from anything this function
      // directly awaits — a try/catch here doesn't see it. Only a zone error
      // handler around where the resolve() call *starts* that chain catches
      // it.
      runZonedGuarded(
        () {
          final stream = const CachedNetworkImageProvider(
            'https://example.com/warmup.jpg',
          ).resolve(ImageConfiguration.empty);
          late ImageStreamListener listener;
          listener = ImageStreamListener(
            (image, sync) {
              stream.removeListener(listener);
              if (!completer.isCompleted) completer.complete();
            },
            onError: (error, stack) {
              stream.removeListener(listener);
              if (!completer.isCompleted) completer.complete();
            },
          );
          stream.addListener(listener);
        },
        (error, stack) {
          // Expected: the one-time databaseFactory failure. Swallow it.
          if (!completer.isCompleted) completer.complete();
        },
      );
      // Best-effort: don't hang the whole suite if this never resolves for
      // some unrelated reason.
      await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
    });

    setUp(() async {
      // CachedNetworkImage (flutter_cache_manager) hits path_provider to find
      // a disk-cache directory; without a mock handler that throws
      // MissingPluginException on the first real image load. Same fix as
      // reading_detail_routing_test.dart (Task 11's own test for this
      // routing).
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => '/tmp',
          );

      // The global image cache persists across tests in this file — clear it
      // so one test's precache calls can't leave stale entries that make a
      // later test's cache assertions pass for the wrong reason.
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      dir = await Directory.systemTemp.createTemp('manga_reader_test');
      Hive.init(dir.path);
      IncognitoMode.notifier.value = false;

      await ReadStore.init();
      await ReadHistory.init();
      await ReaderPrefs.init();

      sl.registerSingleton<ReadStore>(ReadStore());
      spyHistory = _SpyReadHistory(SupabaseService(), () => null);
      sl.registerSingleton<ReadHistory>(spyHistory);
      sl.registerSingleton<ReaderPrefs>(ReaderPrefs());

      ani = AniyomiManager();
      ani.register(
        _FakeReadingProvider('ani:m', {'u1': pages(3), 'u2': pages(2)}),
      );
      sl.registerSingleton<SourceRepository>(
        SourceRepository(
          manager: ProviderManager(dio: Dio()),
          csManager: CloudStreamManager(),
          aniManager: ani,
          activeSource: ActiveSourceCubit(),
          prefs: PlaybackPrefs(),
        ),
      );
    });

    tearDown(() async {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await sl.reset();
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Widget harness({int startIndex = 0}) => MaterialApp(
      home: MangaReaderScreen(
        sourceId: 'ani:m',
        showId: 'm1',
        showTitle: 'Some Manga',
        cover: null,
        chapters: [chapter('c1', 'u1'), chapter('c2', 'u2')],
        startIndex: startIndex,
      ),
    );

    Future<void> disposeHarness(WidgetTester tester) async {
      // Real Hive I/O happens fire-and-forget on dispose (flushed
      // ReadHistory write) — run under runAsync so it actually resolves
      // instead of dangling into tearDown's Hive.close(), same as
      // novel_reader_test.dart.
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    }

    testWidgets('ltr direction renders a non-reversed PageView', (
      tester,
    ) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setDirection('ltr'));
      await tester.pumpWidget(harness());
      await settle(tester);

      expect(find.byType(PageView), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      final pv = tester.widget<PageView>(find.byType(PageView));
      expect(pv.reverse, isFalse);

      await disposeHarness(tester);
    });

    testWidgets('rtl direction renders a reversed PageView', (tester) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setDirection('rtl'));
      await tester.pumpWidget(harness());
      await settle(tester);

      expect(find.byType(PageView), findsOneWidget);
      final pv = tester.widget<PageView>(find.byType(PageView));
      expect(pv.reverse, isTrue);

      await disposeHarness(tester);
    });

    testWidgets('vertical direction renders a ListView, not a PageView', (
      tester,
    ) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setDirection('vertical'));
      await tester.pumpWidget(harness());
      await settle(tester);

      expect(find.byType(ListView), findsOneWidget);
      expect(find.byType(PageView), findsNothing);

      await disposeHarness(tester);
    });

    testWidgets('jumping to a page saves it as the ReadStore position', (
      tester,
    ) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setDirection('ltr'));
      await tester.pumpWidget(harness());
      await settle(tester);

      final pv = tester.widget<PageView>(find.byType(PageView));
      await tester.runAsync(() async {
        pv.controller!.jumpToPage(1); // the chapter's 2nd page (index 1)
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await settle(tester);

      final saved = sl<ReadStore>().get('ani:m', 'm1', 'c1');
      expect(saved, isNotNull);
      expect(saved!.pos, 1);
      expect(saved.total, 3);

      // Pin the other half of the carry-forward contract: a routine page
      // turn (no chapter change, no dispose) must never flush. A regression
      // that flips _saveProgress's default to flush: true would still leave
      // every other assertion in this file green while pushing to Supabase
      // on every page turn.
      expect(spyHistory.flushCalls, everyElement(isFalse));

      await disposeHarness(tester);
    });

    testWidgets(
      'landing on the last page of a chapter scrobbles it exactly once, '
      'with kind: manga',
      (tester) async {
        await tester.runAsync(() => sl<ReaderPrefs>().setDirection('ltr'));
        final fake = _FakeTracker();
        sl.registerSingleton<TrackerHub>(TrackerHub([fake]));

        await tester.pumpWidget(
          MaterialApp(
            home: MangaReaderScreen(
              sourceId: 'ani:m',
              showId: 'm1',
              showTitle: 'Some Manga',
              cover: null,
              chapters: [chapter('c1', 'u1', number: 2), chapter('c2', 'u2')],
              startIndex: 0,
              malId: 555,
            ),
          ),
        );
        await settle(tester);

        final pv = tester.widget<PageView>(find.byType(PageView));
        await tester.runAsync(() async {
          pv.controller!.jumpToPage(2); // last page of a 3-page chapter
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await settle(tester);

        expect(fake.scrobbleCalls, 1);
        expect(fake.lastScrobbleKind, MediaKind.manga);
        expect(fake.lastScrobbleEpisode, 2);
        expect(fake.lastScrobbleMalId, 555);
        // Manga is not a novel — must stay on the plain (unfiltered) search.
        expect(fake.lastScrobbleNovel, isFalse);

        // Committing a slider seek back to the same (still-finished) last
        // page must not scrobble a second time.
        await tester.tapAt(const Offset(400, 300)); // reveal chrome
        await settle(tester);
        final slider = tester.widget<Slider>(find.byType(Slider));
        await tester.runAsync(() async {
          slider.onChangeStart!(2);
          slider.onChangeEnd!(2);
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await settle(tester);
        expect(fake.scrobbleCalls, 1);

        await disposeHarness(tester);
      },
    );

    testWidgets('flushes ReadHistory on chapter change and on dispose', (
      tester,
    ) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setDirection('ltr'));
      await tester.pumpWidget(harness());
      await settle(tester);

      // Chrome (bottom bar) starts hidden — reveal it so the skip_next icon
      // exists to tap.
      await tester.tapAt(const Offset(400, 300));
      await settle(tester);

      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.skip_next_rounded));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await settle(tester);

      expect(spyHistory.flushCalls, contains(true));
      final flushesAfterChapterChange = spyHistory.flushCalls
          .where((f) => f)
          .length;
      expect(flushesAfterChapterChange, greaterThanOrEqualTo(1));

      await disposeHarness(tester);

      final flushesAfterDispose = spyHistory.flushCalls.where((f) => f).length;
      expect(flushesAfterDispose, greaterThan(flushesAfterChapterChange));
    });

    testWidgets(
      'a pages() failure shows the error state (not a crash, not a stuck '
      'spinner), and Retry re-fetches successfully',
      (tester) async {
        ani.register(_FlakyReadingProvider('ani:m', pages(3)));

        await tester.pumpWidget(harness());
        await settle(tester);

        expect(find.text('Retry'), findsOneWidget);
        expect(find.byType(PageView), findsNothing);

        await tester.tap(find.text('Retry'));
        await settle(tester);

        expect(find.text('Retry'), findsNothing);
        expect(find.byType(PageView), findsOneWidget);

        await disposeHarness(tester);
      },
    );

    testWidgets('reopening a chapter restores its saved page', (tester) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setDirection('ltr'));
      // Pre-seed a saved position: page index 2 of a 3-page chapter.
      await tester.runAsync(
        () => sl<ReadStore>().save('ani:m', 'm1', 'c1', pos: 2, total: 3),
      );

      await tester.pumpWidget(harness());
      await settle(tester);

      final pv = tester.widget<PageView>(find.byType(PageView));
      expect(pv.controller!.page, closeTo(2, 0.01));

      await disposeHarness(tester);
    });

    testWidgets(
      'resolveChapters widens a single-chapter Continue Reading resume to '
      'the full list in the background, enabling prev/next',
      (tester) async {
        // Same show as a real resume: the source has 3 chapters, but the
        // reader opens with just the middle one (mirrors what
        // home_screen.dart's readerFor builds from a ReadEntry).
        ani.register(
          _FakeReadingProvider(
            'ani:m',
            {'u1': pages(3), 'u2': pages(2), 'u3': pages(1)},
            episodes: [
              chapter('c1', 'u1'),
              chapter('c2', 'u2'),
              chapter('c3', 'u3'),
            ],
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: MangaReaderScreen(
              sourceId: 'ani:m',
              showId: 'm1',
              showTitle: 'Some Manga',
              cover: null,
              chapters: [chapter('c2', 'u2')],
              startIndex: 0,
              resolveChapters: true,
            ),
          ),
        );
        await settle(tester);

        final prevBtn = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.skip_previous_rounded),
        );
        final nextBtn = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.skip_next_rounded),
        );
        expect(prevBtn.onPressed, isNotNull);
        expect(nextBtn.onPressed, isNotNull);

        await disposeHarness(tester);
      },
    );

    testWidgets(
      'a genuinely single-chapter title stays single — resolveChapters '
      'leaves prev/next disabled when the source only has one chapter',
      (tester) async {
        ani.register(
          _FakeReadingProvider(
            'ani:m',
            {'u1': pages(3)},
            episodes: [chapter('c1', 'u1')],
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: MangaReaderScreen(
              sourceId: 'ani:m',
              showId: 'm1',
              showTitle: 'Some Manga',
              cover: null,
              chapters: [chapter('c1', 'u1')],
              startIndex: 0,
              resolveChapters: true,
            ),
          ),
        );
        await settle(tester);

        final prevBtn = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.skip_previous_rounded),
        );
        final nextBtn = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.skip_next_rounded),
        );
        expect(prevBtn.onPressed, isNull);
        expect(nextBtn.onPressed, isNull);

        await disposeHarness(tester);
      },
    );

    testWidgets('page/chapter header shows "ch n · pg i/N"', (tester) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setDirection('ltr'));
      await tester.pumpWidget(harness());
      await settle(tester);

      // Chrome starts hidden — tap the chrome (center) zone to reveal it.
      await tester.tapAt(const Offset(400, 300)); // center third
      await settle(tester);

      expect(find.textContaining('ch 1 · pg 1/3'), findsOneWidget);

      await disposeHarness(tester);
    });

    testWidgets(
      "a page's CachedNetworkImage receives its real imageUrl and headers "
      '(the exact detail that breaks CF-walled sources if dropped)',
      (tester) async {
        await tester.runAsync(() => sl<ReaderPrefs>().setDirection('ltr'));
        ani.register(
          _FakeReadingProvider('ani:m', {
            'u1': [
              PageImage(
                url: 'https://example.com/cf-page.jpg',
                headers: const {'cf-clearance': 'abc123'},
              ),
            ],
          }),
        );

        await tester.pumpWidget(harness());
        await settle(tester);

        final img = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage),
        );
        expect(img.imageUrl, 'https://example.com/cf-page.jpg');
        expect(img.httpHeaders, const {'cf-clearance': 'abc123'});

        await disposeHarness(tester);
      },
    );

    testWidgets(
      'landing on a page leaves preloaded pages out of the image cache',
      (tester) async {
        await tester.runAsync(() => sl<ReaderPrefs>().setDirection('ltr'));
        final sixPages = pages(6);
        ani.register(_FakeReadingProvider('ani:m', {'u1': sixPages}));

        await tester.pumpWidget(harness());
        await settle(tester);
        final width = _decodeWidthFor(tester);

        // Preloading warms the disk cache and nothing else. It used to call
        // precacheImage, which decoded each page into the global image cache —
        // roughly 28MB a page against a 100MB budget, so a few pages ahead
        // evicted the ones already decoded and the reader paid to decode them
        // again on the way past. Only the page on screen belongs in there now.
        expect(
          await _imageTracked(sixPages[1].url, width),
          isFalse,
          reason: 'preload warms disk, not the image cache',
        );
        expect(
          await _imageTracked(sixPages[4].url, width),
          isFalse,
          reason: 'well outside the window either way',
        );

        await disposeHarness(tester);
      },
    );

    test('preloadWindow stays ahead of the page and inside the chapter', () {
      // The bounds the widget test can no longer observe now that preloading
      // is invisible to the image cache.
      expect(preloadWindow(0, 6, count: 3), [1, 2, 3]);
      expect(preloadWindow(15, 20, count: 3), [16, 17, 18]);
      // Never past the last page, and never the page you're already on.
      expect(preloadWindow(18, 20, count: 3), [19]);
      expect(preloadWindow(19, 20, count: 3), isEmpty);
      // The shipped default reaches further than the three it started with.
      expect(preloadWindow(0, 20, count: 6), [1, 2, 3, 4, 5, 6]);
    });

    // ── Slider drag throttling (paged + vertical) ────────────────────────
    //
    // _seekToPage (Slider.onChanged) jumps the real PageController/
    // ScrollController on every drag tick so the page stays visually in
    // sync with the thumb — but PageController.jumpToPage synchronously
    // fires onPageChanged, and ScrollController.jumpTo synchronously
    // notifies its listeners, both of which are wired to _onPageChanged/
    // _onVerticalScroll. Without the `_seeking` guard, that would preload
    // and save on every tick instead of once, on release. These two tests
    // drive the *real* Slider widget's own callbacks (not
    // PageController.jumpToPage directly, which would miss this regression
    // entirely) across several intermediate ticks, then release.
    //
    // The tick values are deliberately NOT a simple sweep toward the final
    // page: PageView/ListView both build a small cache-extent of pages
    // *adjacent* to whichever page is current — entirely separate from, and
    // legitimate regardless of, `_preload`. A leaked `_preload` call at an
    // intermediate tick would touch a window 1-3 pages further out than
    // that adjacency reaches, so the intermediate ticks are clustered near
    // the start (0-3) and the release is far away (15, in a 20-page
    // chapter) — isolating "would only be tracked if an intermediate tick
    // leaked a preload" (pages 5-6) from "tracked because it's merely
    // adjacent to a visited page" (pages 0-4, 14-16) or "tracked because
    // it's the final commit's own window" (16-18).
    testWidgets(
      'dragging the slider across several pages preloads/saves exactly '
      'once, on release — not per tick (paged)',
      (tester) async {
        await tester.runAsync(() => sl<ReaderPrefs>().setDirection('ltr'));
        final twentyPages = pages(20);
        ani.register(_FakeReadingProvider('ani:m', {'u1': twentyPages}));

        await tester.pumpWidget(harness());
        await settle(tester);
        await tester.tapAt(const Offset(400, 300)); // reveal chrome
        await settle(tester);

        // Clean slate: only what happens during the drag below should show
        // up in the cache assertions (the initial chapter load already
        // preloaded a window of its own).
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        final savesBefore = spyHistory.flushCalls.length;
        final width = _decodeWidthFor(tester);

        final slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChangeStart!(0);
        for (final v in [1.0, 2.0, 3.0]) {
          slider.onChanged!(v);
          await tester.pump();
        }
        slider.onChangeEnd!(15.0);
        await settle(tester);

        expect(
          spyHistory.flushCalls.length - savesBefore,
          1,
          reason: 'one save for the whole drag, not one per tick',
        );
        // The save count above is what proves the drag was throttled. Preload
        // used to be checked here too, by looking for mid-drag pages in the
        // image cache — it warms the disk cache now, so nothing from any tick
        // lands there. `preloadWindow` covers the bounds separately.
        expect(
          await _imageTracked(twentyPages[16].url, width),
          isFalse,
          reason: 'preload warms disk, not the image cache',
        );

        await disposeHarness(tester);
      },
    );

    // Vertical mode's negative ("did an intermediate tick leak a preload")
    // check can't reuse the paged test's ImageCache-tracking trick: measured
    // directly (a throwaway diagnostic jumping ListView's own controller to
    // an arbitrary offset, since deleted), ListView's cache-extent around a
    // 200px-tall item spans roughly 7 items either side of wherever it's
    // scrolled to — versus PageView's ±1 for a full-screen-width item. That
    // 7-item natural window always swallows `_preload`'s 3-page window
    // mathematically, for any chapter length or tick spacing, so a leaked
    // preload and normal ListView windowing are indistinguishable via the
    // image cache here. The save-count assertion below is still fully
    // reliable (ReadHistory.save is entirely our own code, no Flutter
    // internals to confound it) and proves the *_seeking* guard is reached
    // and works for this listener; the same guard, checked immediately
    // above the save-guard in `_onVerticalScroll`, protects `_preload` —
    // and the paged test above already proves that guard mechanism
    // suppresses a real leak when the signal *can* be isolated.
    testWidgets(
      'dragging the slider across several pages saves exactly once, on '
      'release — not per tick (vertical); preload fires for the final '
      'position',
      (tester) async {
        await tester.runAsync(() => sl<ReaderPrefs>().setDirection('vertical'));
        final twentyPages = pages(20);
        ani.register(_FakeReadingProvider('ani:m', {'u1': twentyPages}));

        await tester.pumpWidget(harness());
        await settle(tester);
        await tester.tapAt(const Offset(400, 300)); // reveal chrome
        await settle(tester);

        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        final savesBefore = spyHistory.flushCalls.length;
        final width = _decodeWidthFor(tester);

        final slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChangeStart!(0);
        for (final v in [1.0, 2.0, 3.0]) {
          slider.onChanged!(v);
          await tester.pump();
        }
        slider.onChangeEnd!(15.0);
        await settle(tester);

        expect(
          spyHistory.flushCalls.length - savesBefore,
          1,
          reason: 'one save for the whole drag, not one per tick',
        );
        // This used to prove _commitSeek's preload fired, by finding the
        // window's pages in the image cache. Preload warms the disk cache
        // now, so nothing lands there — the save count above is what shows
        // the seek committed, and `preloadWindow` covers the bounds.
        expect(
          await _imageTracked(twentyPages[16].url, width),
          isFalse,
          reason: 'preload warms disk, not the image cache',
        );

        await disposeHarness(tester);
      },
    );

    // ── Webtoon pinch-zoom ───────────────────────────────────────────────
    //
    // A real two-finger pinch (two TestGesture pointers spreading apart) must
    // scale the strip. The old InteractiveViewer(panEnabled:false) lost the
    // gesture arena for this: the ListView's own vertical-drag recognizer
    // claimed the two-finger gesture before the scale recognizer could, so
    // the pinch was a no-op — the Transform stayed at scale 1. This asserts
    // the strip actually zooms now.
    testWidgets('a two-finger pinch zooms the webtoon strip', (tester) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setDirection('vertical'));
      ani.register(_FakeReadingProvider('ani:m', {'u1': pages(20)}));

      await tester.pumpWidget(harness());
      await settle(tester);

      expect(
        _webtoonScale(tester),
        closeTo(1.0, 0.001),
        reason: 'starts un-zoomed',
      );

      await _pinchOpen(tester);
      await settle(tester);

      expect(
        _webtoonScale(tester),
        greaterThan(1.0),
        reason: 'a two-finger spread must scale the strip',
      );

      await disposeHarness(tester);
    });

    // Guardrail: zoom must not cost the single-finger scroll that drives
    // mark-read-on-scroll-to-bottom. A one-pointer drag still moves the
    // ListView's own controller.
    testWidgets('vertical: a single-finger drag still scrolls the ListView', (
      tester,
    ) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setDirection('vertical'));
      ani.register(_FakeReadingProvider('ani:m', {'u1': pages(20)}));

      await tester.pumpWidget(harness());
      await settle(tester);

      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('manga-listview')),
      );
      expect(list.controller!.offset, 0);

      await tester.drag(
        find.byKey(const ValueKey('manga-listview')),
        const Offset(0, -300),
      );
      await settle(tester);

      expect(list.controller!.offset, greaterThan(0));

      await disposeHarness(tester);
    });

    // Guardrail: a plain single tap still toggles chrome (AnimatedOpacity
    // targets flip 0 -> 1).
    testWidgets('vertical: a single tap still toggles chrome', (tester) async {
      await tester.runAsync(() => sl<ReaderPrefs>().setDirection('vertical'));

      await tester.pumpWidget(harness());
      await settle(tester);

      final before = tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .map((o) => o.opacity);
      expect(before, everyElement(0.0), reason: 'chrome starts hidden');

      await tester.tapAt(const Offset(400, 300));
      await settle(tester);

      final after = tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .map((o) => o.opacity);
      expect(after, everyElement(1.0), reason: 'tap reveals chrome');

      await disposeHarness(tester);
    });
  });
}
