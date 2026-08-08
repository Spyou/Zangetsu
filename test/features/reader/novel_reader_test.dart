import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
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
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tracker/tracker.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/features/reader/novel_reader_screen.dart';

/// A fake reading-capable source that hands back canned text per chapter
/// URL — mirrors `_FakeReadingProvider` in reading_leaf_routing_test.dart,
/// with per-URL text added so a widget test can tell chapters apart.
class _FakeReadingProvider implements BaseProvider, ReadingProvider {
  _FakeReadingProvider(this.sourceId, this.textByUrl);

  @override
  final String sourceId;
  final Map<String, String> textByUrl;

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
  Future<List<PageImage>> getPages(String chapterUrl) =>
      throw UnimplementedError();

  @override
  Future<ChapterText> getText(String chapterUrl) async =>
      ChapterText(html: '<p>${textByUrl[chapterUrl] ?? 'missing'}</p>');
}

/// A reading source whose `getText` throws on the first call and succeeds on
/// every call after — for the error/retry path.
class _FlakyReadingProvider implements BaseProvider, ReadingProvider {
  _FlakyReadingProvider(this.sourceId, this.text);

  @override
  final String sourceId;
  final String text;
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
  Future<List<PageImage>> getPages(String chapterUrl) =>
      throw UnimplementedError();

  @override
  Future<ChapterText> getText(String chapterUrl) async {
    calls++;
    if (calls == 1) throw Exception('network blip');
    return ChapterText(html: '<p>$text</p>');
  }
}

/// Records every `flush` value passed to [ReadHistory.save] (synchronously,
/// before delegating to the real implementation) so the carry-forward
/// requirement — flush on chapter change + on dispose — is provable without
/// reaching into private reader state.
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
  }) async {
    scrobbleCalls++;
    lastScrobbleKind = kind;
    lastScrobbleEpisode = episode;
    lastScrobbleMalId = malId;
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

void main() {
  // AniyomiManager/ProviderManager construction needs the test binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('novelSpans', () {
    test('paragraphs, bold/italic, tags stripped', () {
      // NOTE: the brief's literal fixture used '<p>Next</p>' as the second
      // paragraph and then asserted `isNot(contains('x'))` for the stripped
      // script tag — but "Next" itself contains an 'x', which makes that
      // assertion fail unconditionally regardless of whether script
      // stripping works. Swapped to "Then" (same shape, no incidental 'x')
      // so the assertion tests what it says it tests.
      final spans = novelSpans(
        '<p>Hello <b>bold</b> and <i>it</i></p><p>Then</p>'
        '<script>x</script>',
        const TextStyle(),
      );
      final text = spans.map((s) => s.toPlainText()).join();
      expect(text, contains('Hello bold and it'));
      expect(text, contains('\n')); // paragraph break
      expect(text, isNot(contains('x'))); // script stripped
      expect(spans.any((s) => s.style?.fontWeight == FontWeight.bold), isTrue);
    });

    test('named and numeric entities decode', () {
      final spans = novelSpans(
        '<p>Rock &amp; Roll &mdash; it&#39;s &#x2019;90s &ndash; forever</p>',
        const TextStyle(),
      );
      final text = spans.map((s) => s.toPlainText()).join();
      expect(text, contains('Rock & Roll'));
      expect(text, contains('—')); // &mdash;
      expect(text, contains("it's")); // &#39;
      expect(text, contains('’90s')); // &#x2019;
      expect(text, contains('–')); // &ndash;
    });

    // Regression pin for the reviewer-found crash: String.fromCharCode
    // throws RangeError outside 0..0x10FFFF, and novelSpans runs
    // synchronously from build() — outside the only try/catch in the file
    // (which just guards the network fetch in _load()). A source returning
    // an out-of-range numeric reference must not crash the reader.
    test('a malformed/out-of-range numeric entity does not throw and is left '
        'as raw text', () {
      expect(
        () => novelSpans('<p>Before &#99999999; after</p>', const TextStyle()),
        returnsNormally,
      );
      final spans = novelSpans(
        '<p>Before &#99999999; after</p>',
        const TextStyle(),
      );
      final text = spans.map((s) => s.toPlainText()).join();
      expect(text, contains('Before'));
      expect(text, contains('after'));
      expect(text, contains('&#99999999;')); // left unrecognised, as-is
    });
  });

  group('NovelReaderScreen', () {
    late Directory dir;
    late _SpyReadHistory spyHistory;
    // Exposed so individual tests can swap the registered fake provider
    // in-place (AniyomiManager.register replaces by sourceId) instead of
    // building a second ProviderManager — each one spins up its own QuickJS
    // runtime with an internal periodic timer that's never disposed, and a
    // second one constructed inside a testWidgets body (FakeAsync zone)
    // trips the "pending timer" end-of-test invariant.
    late AniyomiManager ani;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('novel_reader_test');
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
        _FakeReadingProvider('ani:n', {
          'u1': 'chapter one text',
          'u2': 'chapter two text',
        }),
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
      await sl.reset();
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Widget harness() => MaterialApp(
      home: NovelReaderScreen(
        sourceId: 'ani:n',
        showId: 'b1',
        showTitle: 'Book',
        cover: null,
        chapters: [chapter('c1', 'u1'), chapter('c2', 'u2')],
        startIndex: 0,
      ),
    );

    testWidgets('renders chapter text and advances to next chapter', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      expect(find.textContaining('chapter one text'), findsOneWidget);

      // chrome → next
      await tester.tap(find.byType(SingleChildScrollView));
      await tester.pumpAndSettle();

      // Advancing writes a flushed ReadHistory entry, which is real Hive
      // I/O — run it under runAsync so the fire-and-forget write actually
      // resolves instead of dangling into tearDown's Hive.close().
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.skip_next_rounded));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('chapter two text'), findsOneWidget);

      // Explicitly dispose the reader (under runAsync, same reason as
      // above) instead of relying on the framework's between-test teardown
      // — dispose() also fire-and-forgets a flushed ReadHistory write, and
      // letting that dangle outside runAsync hangs tearDown's Hive.close().
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    });

    testWidgets('flushes ReadHistory on chapter change and on dispose', (
      tester,
    ) async {
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(SingleChildScrollView));
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.skip_next_rounded));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(spyHistory.flushCalls, contains(true));
      final flushesAfterChapterChange = spyHistory.flushCalls
          .where((f) => f)
          .length;
      expect(flushesAfterChapterChange, greaterThanOrEqualTo(1));

      // Tear the whole tree down — this disposes NovelReaderScreen's State.
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      final flushesAfterDispose = spyHistory.flushCalls.where((f) => f).length;
      expect(flushesAfterDispose, greaterThan(flushesAfterChapterChange));
    });

    testWidgets(
      'a chapterText failure shows the error state (not a crash, not a '
      'stuck spinner), and Retry re-fetches successfully',
      (tester) async {
        // Swap in a source that fails once then succeeds, in place of the
        // shared setUp's always-succeeding fake — replaces the 'ani:n' entry
        // on the same AniyomiManager/SourceRepository setUp already built.
        ani.register(_FlakyReadingProvider('ani:n', 'chapter one text'));

        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        expect(find.text('Retry'), findsOneWidget);
        expect(find.textContaining('chapter one text'), findsNothing);

        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();

        expect(find.textContaining('chapter one text'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);

        // Dispose under runAsync — same reason as the tests above.
        await tester.runAsync(() async {
          await tester.pumpWidget(const SizedBox());
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
      },
    );

    testWidgets('reopening a chapter restores its saved scroll permille', (
      tester,
    ) async {
      // A long chapter so it actually scrolls in the test viewport, so the
      // restore has something non-trivial to prove.
      final longText = List.generate(
        120,
        (i) => 'Paragraph number $i with enough words to take real space.',
      ).join('</p><p>');
      // Same reasoning as the error/retry test: replace the fake in-place on
      // the existing AniyomiManager rather than building a second
      // ProviderManager.
      ani.register(_FakeReadingProvider('ani:n', {'u1': longText}));
      // Pre-seed a saved position: 50% scrolled. Real Hive I/O awaited
      // directly (not fire-and-forget like the production code), so it
      // needs runAsync too — a plain await inside testWidgets' FakeAsync
      // zone never resolves a real dart:io completion.
      await tester.runAsync(
        () => sl<ReadStore>().save('ani:n', 'b1', 'c1', pos: 500, total: 1000),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: NovelReaderScreen(
            sourceId: 'ani:n',
            showId: 'b1',
            showTitle: 'Book',
            cover: null,
            chapters: [chapter('c1', 'u1')],
            startIndex: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      final controller = scrollView.controller!;
      final maxExtent = controller.position.maxScrollExtent;
      expect(maxExtent, greaterThan(0)); // sanity: the chapter actually scrolls

      final expectedOffset = 0.5 * maxExtent; // 500 / 1000 permille
      expect(controller.offset, closeTo(expectedOffset, 1.0));

      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
    });

    testWidgets('reaching the end of a chapter scrobbles it exactly once, with '
        'kind: manga', (tester) async {
      final longText = List.generate(
        120,
        (i) => 'Paragraph number $i with enough words to take real space.',
      ).join('</p><p>');
      ani.register(_FakeReadingProvider('ani:n', {'u1': longText}));
      final fake = _FakeTracker();
      sl.registerSingleton<TrackerHub>(TrackerHub([fake]));

      await tester.pumpWidget(
        MaterialApp(
          home: NovelReaderScreen(
            sourceId: 'ani:n',
            showId: 'b1',
            showTitle: 'Book',
            cover: null,
            chapters: [chapter('c1', 'u1', number: 3)],
            startIndex: 0,
            malId: 777,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      final controller = scrollView.controller!;

      await tester.runAsync(() async {
        controller.jumpTo(controller.position.maxScrollExtent);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(fake.scrobbleCalls, 1);
      expect(fake.lastScrobbleKind, MediaKind.manga);
      expect(fake.lastScrobbleEpisode, 3);
      expect(fake.lastScrobbleMalId, 777);

      // Dispose flushes progress again for the same (still-finished)
      // chapter — must not scrobble a second time.
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(fake.scrobbleCalls, 1);
    });
  });
}
