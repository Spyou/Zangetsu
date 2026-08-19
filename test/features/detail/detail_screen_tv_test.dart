// Tests for the TV two-pane Detail layout.
//
// DI/BlocProvider setup mirrors root_shell_tv_test.dart: minimal GetIt stubs
// (no Hive, no platform channels) + DetailCubit pre-loaded via a stub
// SourceRepository. DetailScreenTv is part of detail_screen.dart's library,
// so we import detail_screen.dart to access it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_record.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/media_extras.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/core/playback/title_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/base_provider.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/detail/cubit/detail_cubit.dart';
import 'package:watch_app/features/detail/detail_screen.dart';

// ── Minimal stubs — no Hive, no platform channels ────────────────────────────

/// Stub [SourceRepository] that returns a pre-built [MediaDetail].
class _StubSourceRepository implements SourceRepository {
  _StubSourceRepository(this._detail);
  final MediaDetail _detail;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) async =>
      _detail;

  @override
  void prefetch(String url, {String? sourceId}) {}

  @override
  String get sourceId => 'test';

  @override
  bool hasSource(String id) => false;

  @override
  String displayName(String id) => id;

  @override
  List<({String id, String name})> get loadedSources => const [];
}

/// Stub [TitlePrefsStore] — no Hive, always returns null.
class _FakeTitlePrefs extends TitlePrefsStore {
  @override
  String? category(String s, String u) => null;

  @override
  Future<void> setCategory(String s, String u, String c) async {}
}

/// Stub [MyListStore] — empty list, no Hive.
class _FakeMyListStore implements MyListStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool contains(MediaItem m) => false;

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

/// Stub [ListStatusStore] — no status, no Hive.
class _FakeListStatusStore implements ListStatusStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  WatchStatus? statusOf(MediaItem m) => null;

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

/// Stub [ResumeStore] — no saved positions, no Hive.
class _FakeResumeStore implements ResumeStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  ResumeMark? get(String sourceId, String showId, String episodeId) => null;
}

/// Stub [ProviderRegistry] — no registered providers.
class _FakeProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;

  @override
  List<ProviderRegistryEntry> getAll() => const [];
}

/// Stub [CloudStreamManager] — no CS providers.
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

/// Stub [DownloadManager] — no downloads, no Hive, no file downloader.
class _FakeDownloadManager extends ChangeNotifier implements DownloadManager {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  DownloadRecord? recordFor(
    String sourceId,
    String showId,
    String episodeId,
  ) =>
      null;
}

// ── Test data ─────────────────────────────────────────────────────────────────

const _testItem = MediaItem(
  id: 'test-show',
  title: 'Test Anime',
  url: 'http://test/show',
  type: ProviderType.anime,
  sourceId: 'test',
);

const _testDetail = MediaDetail(
  id: 'test-show',
  title: 'Test Anime',
  url: 'http://test/show',
  type: ProviderType.anime,
  sourceId: 'test',
  episodes: [
    Episode(id: 'e1', title: 'Episode 1', url: '/e1', number: 1),
    Episode(id: 'e2', title: 'Episode 2', url: '/e2', number: 2),
    Episode(id: 'e3', title: 'Episode 3', url: '/e3', number: 3),
  ],
);

// Multi-season: episode titles carry "S<n> E<n>" prefix so [seasonsOf] returns
// {1, 2} and the TV season chip row is rendered.
const _testDetailMultiSeason = MediaDetail(
  id: 'ms-show',
  title: 'Multi Season Anime',
  url: 'http://test/ms',
  type: ProviderType.anime,
  sourceId: 'test',
  episodes: [
    Episode(id: 's1e1', title: 'S1 E1 - Pilot', url: '/s1e1', number: 1),
    Episode(id: 's1e2', title: 'S1 E2 - Second', url: '/s1e2', number: 2),
    Episode(id: 's2e1', title: 'S2 E1 - Season Two', url: '/s2e1', number: 1),
  ],
);

// Detail that includes source-supplied relations so [_enrich]'s fallback path
// emits them into state without needing AniList / TMDB.
const _testDetailWithRelations = MediaDetail(
  id: 'rel-show',
  title: 'Relations Anime',
  url: 'http://test/rel',
  type: ProviderType.anime,
  sourceId: 'test',
  episodes: [
    Episode(id: 'e1', title: 'Episode 1', url: '/e1', number: 1),
  ],
  relations: [
    MediaRelation(title: 'Sequel Anime', relation: 'Sequel'),
    MediaRelation(title: 'Prequel Anime', relation: 'Prequel'),
  ],
);

// ── Test ──────────────────────────────────────────────────────────────────────

void main() {
  late DetailCubit cubit;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    // Mock path_provider so any indirect AppwriteService init doesn't throw.
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );

    // Reset GetIt so each test starts clean.
    await sl.reset();

    // Register minimal stubs for every sl<> call that fires during render.
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<ListStatusStore>(_FakeListStatusStore());
    sl.registerSingleton<ResumeStore>(_FakeResumeStore());
    sl.registerSingleton<ProviderRegistry>(_FakeProviderRegistry());
    sl.registerSingleton<CloudStreamManager>(_FakeCloudStreamManager());
    sl.registerSingleton<DownloadManager>(_FakeDownloadManager());
    // Build reads TrackerHub (_maybeFetchTrackerProgress / _trackingAvailable).
    // No trackers → anyConnected == false, so both bail before touching the
    // binding store or rendering the Tracking button.
    sl.registerSingleton<TrackerHub>(TrackerHub(const []));

    // Build and pre-load a DetailCubit so the widget renders the success state.
    final fakePrefs = _FakeTitlePrefs();
    cubit = DetailCubit(
      repo: _StubSourceRepository(_testDetail),
      url: _testItem.url,
      sourceId: _testItem.sourceId,
      prefs: fakePrefs,
    );
    await cubit.load();
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    cubit.close();
    await sl.reset();
  });

  testWidgets(
    'DetailScreenTv renders the Play button and episode tiles as TvFocusables',
    (tester) async {
      await tester.pumpWidget(
        BlocProvider<DetailCubit>.value(
          value: cubit,
          child: MaterialApp(
            home: DetailScreenTv(item: _testItem),
          ),
        ),
      );
      await tester.pump(); // let BlocBuilder resolve

      // The title should appear in the left info pane.
      expect(find.text('Test Anime'), findsWidgets);

      // The Play button (keyed 'tv-detail-play') must be present and be a
      // TvFocusable with autofocus: true.
      expect(
        find.byKey(const ValueKey('tv-detail-play')),
        findsOneWidget,
      );
      final playFocusable = tester.widget<TvFocusable>(
        find.byKey(const ValueKey('tv-detail-play')),
      );
      expect(playFocusable.autofocus, isTrue);

      // 'Play' text inside the Play button.
      expect(find.text('Play'), findsWidgets);

      // Three episode tiles should each be wrapped in TvFocusable.
      expect(find.byKey(const ValueKey('tv-ep-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-ep-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-ep-2')), findsOneWidget);

      // Every keyed episode tile is a TvFocusable.
      for (int i = 0; i < 3; i++) {
        final w = tester.widget<TvFocusable>(
          find.byKey(ValueKey('tv-ep-$i')),
        );
        expect(w, isA<TvFocusable>());
      }

      // At least the Play + Download + My List + 4 tabs + 3 episodes are focusable.
      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();
      expect(focusables.length, greaterThanOrEqualTo(8));

      // The two focus scope nodes for the left/right panes are in the tree.
      final scopeNodes = <FocusScopeNode>[];
      void visitScope(FocusNode node) {
        if (node is FocusScopeNode &&
            (node.debugLabel ?? '').startsWith('tv-detail-')) {
          scopeNodes.add(node);
        }
        for (final child in node.children) {
          visitScope(child);
        }
      }
      visitScope(tester.binding.focusManager.rootScope);
      expect(
        scopeNodes.map((n) => n.debugLabel).toSet(),
        containsAll(['tv-detail-left', 'tv-detail-right']),
      );
    },
  );

  // ── GAP 3: season chips ───────────────────────────────────────────────────

  testWidgets(
    'DetailScreenTv shows TvFocusable season chips for multi-season titles',
    (tester) async {
      final seasonCubit = DetailCubit(
        repo: _StubSourceRepository(_testDetailMultiSeason),
        url: _testDetailMultiSeason.url,
        sourceId: _testDetailMultiSeason.sourceId,
        prefs: _FakeTitlePrefs(),
      );
      await seasonCubit.load();
      addTearDown(seasonCubit.close);

      final multiItem = const MediaItem(
        id: 'ms-show',
        title: 'Multi Season Anime',
        url: 'http://test/ms',
        type: ProviderType.anime,
        sourceId: 'test',
      );

      await tester.pumpWidget(
        BlocProvider<DetailCubit>.value(
          value: seasonCubit,
          child: MaterialApp(
            home: DetailScreenTv(item: multiItem),
          ),
        ),
      );
      await tester.pump();

      // Season 1 and Season 2 chips must be present and be TvFocusables.
      expect(find.byKey(const ValueKey('tv-season-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-season-2')), findsOneWidget);

      final chip1 = tester.widget<TvFocusable>(
        find.byKey(const ValueKey('tv-season-1')),
      );
      expect(chip1, isA<TvFocusable>());

      final chip2 = tester.widget<TvFocusable>(
        find.byKey(const ValueKey('tv-season-2')),
      );
      expect(chip2, isA<TvFocusable>());

      // Season 1 episodes are shown by default (3 total but only 2 in S1).
      expect(find.byKey(const ValueKey('tv-ep-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-ep-1')), findsOneWidget);
    },
  );

  // ── GAP 1: Relations tab TvFocusable ──────────────────────────────────────

  testWidgets(
    'DetailScreenTv wraps each relation card in TvFocusable (tvFocus: true)',
    (tester) async {
      final relCubit = DetailCubit(
        repo: _StubSourceRepository(_testDetailWithRelations),
        url: _testDetailWithRelations.url,
        sourceId: _testDetailWithRelations.sourceId,
        prefs: _FakeTitlePrefs(),
      );
      await relCubit.load();
      addTearDown(relCubit.close);

      // Verify the cubit state has relations populated via _enrich's fallback.
      expect(
        relCubit.state.relations.length,
        2,
        reason: '_enrich should emit source-supplied relations for anime '
            'without malId/tmdbId',
      );

      final relItem = const MediaItem(
        id: 'rel-show',
        title: 'Relations Anime',
        url: 'http://test/rel',
        type: ProviderType.anime,
        sourceId: 'test',
      );

      await tester.pumpWidget(
        BlocProvider<DetailCubit>.value(
          value: relCubit,
          child: MaterialApp(
            home: DetailScreenTv(item: relItem),
          ),
        ),
      );
      await tester.pump();

      // TvFocusable uses Focus + key events, NOT a GestureDetector, so
      // tester.tap() does not trigger its onTap.  Access onTap directly —
      // equivalent to pressing D-pad OK on the TV remote.
      expect(
        find.byKey(const ValueKey('tv-detail-tab-2')),
        findsOneWidget,
        reason: 'Relations tab key must be in the tree',
      );
      final relTab = tester.widget<TvFocusable>(
        find.byKey(const ValueKey('tv-detail-tab-2')),
      );
      relTab.onTap(); // programmatically invoke — same as D-pad OK press
      await tester.pump();

      // Relations tab is now visible; GridView builds its items.
      // "No related titles" must NOT appear — that would mean relations are empty.
      expect(find.text('No related titles'), findsNothing);

      // Both relation cards must now be keyed TvFocusables.
      expect(find.byKey(const ValueKey('tv-rel-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-rel-1')), findsOneWidget);

      final rel0 = tester.widget<TvFocusable>(
        find.byKey(const ValueKey('tv-rel-0')),
      );
      expect(rel0, isA<TvFocusable>());

      final rel1 = tester.widget<TvFocusable>(
        find.byKey(const ValueKey('tv-rel-1')),
      );
      expect(rel1, isA<TvFocusable>());
    },
  );

  // ── Semantics labels (TalkBack) ────────────────────────────────────────

  testWidgets(
    'DetailScreenTv exposes semantics labels for Play/Download/My List and '
    'episode rows — with no duplicate-text nodes',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        BlocProvider<DetailCubit>.value(
          value: cubit,
          child: MaterialApp(home: DetailScreenTv(item: _testItem)),
        ),
      );
      await tester.pump();

      // Play button — autofocused, label is the visible button text ('Play',
      // no watch history in this fixture).
      expect(
        tester.getSemantics(find.byKey(const ValueKey('tv-detail-play'))),
        matchesSemantics(
          label: 'Play',
          isButton: true,
          isFocusable: true,
          isFocused: true,
          hasTapAction: true,
          // Framework-supplied for anything focusable; matchesSemantics fails
          // on any action it wasn't told to expect.
          hasFocusAction: true,
        ),
      );

      // Download / My List buttons.
      expect(
        tester.getSemantics(find.byKey(const ValueKey('tv-detail-download'))),
        matchesSemantics(
          label: 'Download',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.byKey(const ValueKey('tv-detail-mylist'))),
        matchesSemantics(
          label: 'My List',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );

      // Episode rows announce "N. Title" (or "Episode N" when titleless) —
      // the fixture's episodes are literally titled 'Episode 1'/'2'/'3', and
      // only ONE node in the tree carries each (the shared _EpisodeRow's own
      // heading Text is excluded, so it isn't announced twice).
      for (final label in ['1. Episode 1', '2. Episode 2', '3. Episode 3']) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }

      // Tab bar — each tab announces its own name.
      expect(find.bySemanticsLabel('Episodes'), findsOneWidget);
      expect(find.bySemanticsLabel('Cast'), findsOneWidget);
      expect(find.bySemanticsLabel('Relations'), findsOneWidget);
      expect(find.bySemanticsLabel('Details'), findsOneWidget);

      handle.dispose();
    },
  );

  testWidgets(
    'DetailScreenTv season chips expose "Season N" as their semantics label',
    (tester) async {
      final handle = tester.ensureSemantics();
      final seasonCubit = DetailCubit(
        repo: _StubSourceRepository(_testDetailMultiSeason),
        url: _testDetailMultiSeason.url,
        sourceId: _testDetailMultiSeason.sourceId,
        prefs: _FakeTitlePrefs(),
      );
      await seasonCubit.load();
      addTearDown(seasonCubit.close);

      await tester.pumpWidget(
        BlocProvider<DetailCubit>.value(
          value: seasonCubit,
          child: const MaterialApp(
            home: DetailScreenTv(
              item: MediaItem(
                id: 'ms-show',
                title: 'Multi Season Anime',
                url: 'http://test/ms',
                type: ProviderType.anime,
                sourceId: 'test',
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Only ONE node carries each season label — the chip's own "Season N"
      // Text is excluded so semanticLabel is the sole announcement.
      expect(find.bySemanticsLabel('Season 1'), findsOneWidget);
      expect(find.bySemanticsLabel('Season 2'), findsOneWidget);

      handle.dispose();
    },
  );

  // ── D-pad bridge: _onLeftKey / _onRightKey ─────────────────────────────────
  //
  // The old accessibleNavigation gate was removed (commit 1ef97f8): Fire TV /
  // onn falsely report accessibleNavigation: true after the native player,
  // which dead-keyed the D-pad. Both handlers now bridge left ↔ right the same
  // way REGARDLESS of accessibleNavigation — the screen-reader-ON case behaves
  // exactly like the screen-reader-OFF (sighted user) case.

  testWidgets(
    'DetailScreenTv _onLeftKey: arrowRight bridges left → right when a '
    'screen reader is OFF (sighted user, original behaviour)',
    (tester) async {
      await tester.pumpWidget(
        BlocProvider<DetailCubit>.value(
          value: cubit,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(accessibleNavigation: false),
              child: DetailScreenTv(item: _testItem),
            ),
          ),
        ),
      );
      await tester.pump();

      final playFocus = tester.binding.focusManager.primaryFocus;
      expect(playFocus, isNotNull);
      expect(playFocus?.nearestScope?.debugLabel, 'tv-detail-left');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(
        tester.binding.focusManager.primaryFocus?.nearestScope?.debugLabel,
        'tv-detail-right',
      );
    },
  );

  testWidgets(
    'DetailScreenTv _onLeftKey: arrowRight STILL bridges left → right when a '
    'screen reader is ON (Fire TV / onn falsely report accessibleNavigation, '
    'so the D-pad bridge must not dead-key)',
    (tester) async {
      await tester.pumpWidget(
        BlocProvider<DetailCubit>.value(
          value: cubit,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(accessibleNavigation: true),
              child: DetailScreenTv(item: _testItem),
            ),
          ),
        ),
      );
      await tester.pump();

      final playFocus = tester.binding.focusManager.primaryFocus;
      expect(playFocus, isNotNull);
      expect(playFocus?.nearestScope?.debugLabel, 'tv-detail-left');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      expect(
        tester.binding.focusManager.primaryFocus?.nearestScope?.debugLabel,
        'tv-detail-right',
      );
    },
  );

  testWidgets(
    'DetailScreenTv _onRightKey: arrowLeft bridges right → left when a '
    'screen reader is OFF (sighted user, original behaviour)',
    (tester) async {
      await tester.pumpWidget(
        BlocProvider<DetailCubit>.value(
          value: cubit,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(accessibleNavigation: false),
              child: DetailScreenTv(item: _testItem),
            ),
          ),
        ),
      );
      await tester.pump();

      final playFocus = tester.binding.focusManager.primaryFocus;
      expect(playFocus, isNotNull);

      // Get into the right pane first (via the already-tested _onLeftKey).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        tester.binding.focusManager.primaryFocus?.nearestScope?.debugLabel,
        'tv-detail-right',
      );

      // arrowLeft at the right pane's left edge (nothing further left to
      // traverse to intra-pane) → _onRightKey crosses back to the left pane,
      // restoring the previously-focused Play button (ORIGINAL behaviour).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(tester.binding.focusManager.primaryFocus, same(playFocus));
    },
  );

  testWidgets(
    'DetailScreenTv _onRightKey: arrowLeft STILL bridges right → left when a '
    'screen reader is ON (mirrors the OFF case — the gate is gone)',
    (tester) async {
      await tester.pumpWidget(
        BlocProvider<DetailCubit>.value(
          value: cubit,
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(accessibleNavigation: true),
              child: DetailScreenTv(item: _testItem),
            ),
          ),
        ),
      );
      await tester.pump();

      final playFocus = tester.binding.focusManager.primaryFocus;
      expect(playFocus, isNotNull);

      // Get into the right pane first (via _onLeftKey, which now works with a
      // screen reader on too).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        tester.binding.focusManager.primaryFocus?.nearestScope?.debugLabel,
        'tv-detail-right',
      );

      // arrowLeft at the right pane's left edge → _onRightKey crosses back to
      // the left pane, restoring the previously-focused Play button — even
      // with accessibleNavigation on.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(tester.binding.focusManager.primaryFocus, same(playFocus));
    },
  );
}
