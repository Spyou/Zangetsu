import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/playback/watch_history.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/theme/app_colors.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/core/zmode/metadata_repository.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';
import 'package:watch_app/features/home/home_catalogue_prefs.dart';
import 'package:watch_app/features/home/home_screen_tv.dart';
import 'package:watch_app/features/home/source_catalogue_home_content.dart';
import 'package:watch_app/core/ui/source_switcher.dart';

// ── Minimal fake ──────────────────────────────────────────────────────────────

/// Stub [SourceRepository] whose [home] returns the provided sections.
/// All other methods are noSuchMethod-guarded — they throw if called.
class _StubSourceRepository implements SourceRepository {
  const _StubSourceRepository(this._sections, {this.loaded = const []});

  final List<HomeSection> _sections;
  final List<({String id, String name})> loaded;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  @override
  Future<bool> ensureSourceLoaded(String sourceId) async => true;

  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async => _sections;

  @override
  String displayName(String id) => id;

  @override
  String get sourceId => loaded.firstOrNull?.id ?? 'test';

  @override
  List<({String id, String name})> get loadedSources => loaded;

  @override
  bool hasSource(String id) => loaded.any((source) => source.id == id);
}

class _BlockingEpisodesRepository extends _StubSourceRepository {
  _BlockingEpisodesRepository(super._sections);

  final episodesResult = Completer<List<Episode>>();
  final sourceLoadChecks = <String>[];
  int episodeCalls = 0;

  @override
  Future<bool> ensureSourceLoaded(String sourceId) async {
    sourceLoadChecks.add(sourceId);
    return true;
  }

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) {
    episodeCalls++;
    return episodesResult.future;
  }
}

class _EmptyProviderManager implements ProviderManager {
  @override
  JsProvider? get(String id) => null;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _UnavailableJsRegistry implements ProviderRegistry {
  @override
  String? typeOf(String sourceId) => 'anime';

  @override
  Future<bool> ensureRuntimeLoaded(
    String sourceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async => false;

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _WarmMetadataRepository implements MetadataRepository {
  final warmed = <ZKind>[];

  @override
  Future<List<HomeSection>> ensureHomeCached(ZKind kind) async {
    warmed.add(kind);
    return const [];
  }

  @override
  List<HomeSection>? peekHomeCache(ZKind kind) => null;

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Fake [AuthCubit] with the default (logged-out) state — Continue Watching is
/// login-gated, so this keeps the rail hidden and avoids needing WatchHistory.
class _FakeAuthCubit extends Cubit<AuthState> implements AuthCubit {
  _FakeAuthCubit() : super(const AuthState());
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  // Added with the on-demand resolver: SourceMatcher now asks whether a JS
  // provider is loaded before searching it. These fakes are already "loaded".
  Future<bool> ensureSourceLoaded(String sourceId) async => true;
}

class _FakeContentModeCubit extends Cubit<ContentMode>
    implements ContentModeCubit {
  _FakeContentModeCubit() : super(ContentMode.anime);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _homeApp(HomeCubit cubit, {ActiveSourceCubit? activeSource}) =>
    MultiBlocProvider(
      providers: [
        BlocProvider<HomeCubit>.value(value: cubit),
        BlocProvider<AuthCubit>.value(value: _FakeAuthCubit()),
        BlocProvider<ActiveSourceCubit>.value(
          value: activeSource ?? ActiveSourceCubit(),
        ),
      ],
      child: const MaterialApp(home: HomeScreenTv()),
    );

Future<void> _changeCatalogue(WidgetTester tester, VoidCallback action) async {
  final revision = HomeCataloguePrefs.revision.value;
  await tester.runAsync(() async => action());
  final timeout = Stopwatch()..start();
  while (HomeCataloguePrefs.revision.value == revision &&
      timeout.elapsed < const Duration(seconds: 5)) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(HomeCataloguePrefs.revision.value, greaterThan(revision));
}

// ── Test ──────────────────────────────────────────────────────────────────────

void main() {
  // Two items in one section — enough to verify hero + rail rendering.
  const testItems = [
    MediaItem(
      id: '1',
      title: 'Anime One',
      url: '/1',
      type: ProviderType.anime,
      sourceId: 'test',
    ),
    MediaItem(
      id: '2',
      title: 'Anime Two',
      url: '/2',
      type: ProviderType.anime,
      sourceId: 'test',
    ),
  ];

  late HomeCubit cubit;
  late _FakeContentModeCubit contentMode;

  setUp(() async {
    contentMode = _FakeContentModeCubit();
    sl.registerSingleton<ContentModeCubit>(contentMode);
    final sections = [
      const HomeSection(title: 'Trending Now', items: testItems),
    ];
    final repo = _StubSourceRepository(sections);
    cubit = HomeCubit(repo);
    if (sl.isRegistered<CatalogueRepository>()) {
      sl.unregister<CatalogueRepository>();
    }
    sl.registerSingleton<CatalogueRepository>(repo);
    // Load populates the cubit state before the widget is pumped.
    await cubit.load();
  });

  tearDown(() async {
    sl.unregister<ContentModeCubit>();
    await contentMode.close();
    await cubit.close();
  });

  testWidgets(
    'HomeScreenTv renders rail items and the first focusable has autofocus',
    (tester) async {
      await tester.pumpWidget(_homeApp(cubit));
      await tester.pumpAndSettle();

      // Hero title + poster card title both contain 'Anime One'.
      expect(find.text('Anime One'), findsWidgets);
      // 'Anime Two' appears only in the rail poster card.
      expect(find.text('Anime Two'), findsOneWidget);

      // At least the hero buttons + rail cards are wrapped in TvFocusable.
      final focusables = tester
          .widgetList<TvFocusable>(find.byType(TvFocusable))
          .toList();
      expect(focusables, isNotEmpty);

      // The hero Play button keeps initial focus after the header enters the scroll.
      expect(
        focusables.firstWhere((f) => f.semanticLabel == 'Play').autofocus,
        isTrue,
      );

      // Poster rail cards must wire held-OK long-press (info sheet). Without
      // this, TvFocusable treats OK as an immediate tap and long-hold is dead.
      final poster = focusables.firstWhere(
        (f) => f.semanticLabel == 'Anime Two',
      );
      expect(poster.onLongPress, isNotNull);
    },
  );

  testWidgets('TV header scrolls with the banner and has no solid backing', (
    tester,
  ) async {
    await tester.pumpWidget(_homeApp(cubit));
    await tester.pumpAndSettle();

    final header = find.byKey(const ValueKey('tv-home-header'));
    final scroll = find.byType(CustomScrollView).first;
    expect(
      tester.getTopLeft(header).dy,
      greaterThanOrEqualTo(tester.getTopLeft(scroll).dy),
    );
    expect(
      find.descendant(
        of: header,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is AssetImage &&
              (widget.image as AssetImage).assetName ==
                  'assets/icon/logo_mark.png',
        ),
      ),
      findsOneWidget,
    );

    expect(
      find.ancestor(
        of: header,
        matching: find.byWidgetPredicate(
          (widget) => widget is ColoredBox && widget.color == AppColors.bg,
        ),
      ),
      findsNothing,
    );
    await tester.drag(scroll, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(header, findsNothing);
  });

  testWidgets('TV hero is a compact inset card rather than edge-to-edge', (
    tester,
  ) async {
    await tester.pumpWidget(_homeApp(cubit));
    await tester.pumpAndSettle();

    final hero = find.byKey(const ValueKey('tv-home-hero-card'));
    final scroll = find.byType(CustomScrollView).first;
    expect(
      tester.getTopLeft(hero).dx,
      closeTo(tester.getTopLeft(scroll).dx + 4, 0.5),
    );
    expect(
      tester.getSize(hero).width,
      closeTo(tester.getSize(scroll).width - 32, 0.5),
    );
    expect(
      tester.getSize(hero).height,
      lessThan(MediaQuery.sizeOf(tester.element(scroll)).height * 0.65),
    );
    expect(
      tester.widget<ClipRSuperellipse>(hero).borderRadius,
      BorderRadius.circular(28),
    );
  });

  testWidgets(
    'TV Home shows centered catalogue tabs and conditional source chip',
    (tester) async {
      late Directory prefsDir;
      await tester.runAsync(() async {
        prefsDir = await Directory.systemTemp.createTemp('tv_header_catalogue');
        Hive.init(prefsDir.path);
        await Hive.openBox(HomeCataloguePrefs.boxName);
      });
      addTearDown(() async {
        await Hive.close();
        await prefsDir.delete(recursive: true);
      });
      final previousSourceRepository = sl.isRegistered<SourceRepository>()
          ? sl<SourceRepository>()
          : null;
      final previousCloudStreamManager = sl.isRegistered<CloudStreamManager>()
          ? sl<CloudStreamManager>()
          : null;
      if (previousSourceRepository != null) sl.unregister<SourceRepository>();
      if (previousCloudStreamManager != null) {
        sl.unregister<CloudStreamManager>();
      }
      const sourceSections = [
        HomeSection(
          title: 'Recommended',
          items: [
            MediaItem(
              id: 'source-hero',
              title: 'Source Hero Title',
              url: '/source-hero',
              type: ProviderType.anime,
              sourceId: 'cs:source_one',
            ),
          ],
        ),
        HomeSection(
          title: 'Recently Added',
          items: [
            MediaItem(
              id: 'source-row',
              title: 'Source Row Title',
              url: '/source-row',
              type: ProviderType.anime,
              sourceId: 'cs:source_one',
            ),
          ],
        ),
      ];
      sl.registerSingleton<SourceRepository>(
        const _StubSourceRepository(
          sourceSections,
          loaded: [
            (id: 'cs:source_one', name: 'Source One'),
            (id: 'cs:source_two', name: 'Source Two'),
          ],
        ),
      );
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
      final previousAppMode = sl.isRegistered<AppMode>() ? sl<AppMode>() : null;
      if (previousAppMode != null) sl.unregister<AppMode>();
      sl.registerSingleton<AppMode>(const AppMode(isTv: true));
      addTearDown(() {
        if (sl.isRegistered<SourceRepository>()) {
          sl.unregister<SourceRepository>();
        }
        if (previousSourceRepository != null) {
          sl.registerSingleton<SourceRepository>(previousSourceRepository);
        }
        if (sl.isRegistered<CloudStreamManager>()) {
          sl.unregister<CloudStreamManager>();
        }
        if (previousCloudStreamManager != null) {
          sl.registerSingleton<CloudStreamManager>(previousCloudStreamManager);
        }
        if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
        if (previousAppMode != null) {
          sl.registerSingleton<AppMode>(previousAppMode);
        }
      });

      final activeSource = ActiveSourceCubit(fallback: 'cs:source_one');
      await tester.pumpWidget(_homeApp(cubit, activeSource: activeSource));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('tv-home-catalogue-menu')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('tv-home-tab-anime')), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-home-tab-movie')), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-home-tab-source')), findsOneWidget);
      expect(find.byKey(const ValueKey('tv-home-tab-stremio')), findsOneWidget);
      expect(find.byType(SourceSwitcher), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tv-home-tab-anime')),
          matching: find.byKey(const ValueKey('tv-home-selected-chip')),
        ),
        findsOneWidget,
      );
      final selected = tester.widget<Container>(
        find.byKey(const ValueKey('tv-home-selected-chip')),
      );
      expect((selected.decoration as BoxDecoration).color, Colors.white);
      expect(
        (selected.decoration as BoxDecoration).borderRadius,
        BorderRadius.circular(24),
      );

      await tester.runAsync(
        () => HomeCataloguePrefs.setSourceIdFor(
          ContentMode.anime,
          'cs:source_one',
        ),
      );
      await tester.runAsync(
        () => HomeCataloguePrefs.setCatalogue(
          ContentMode.anime,
          HomeCatalogueKind.source,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SourceCatalogueHomeContent), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tv-home-tab-source')),
          matching: find.byKey(const ValueKey('tv-home-selected-chip')),
        ),
        findsOneWidget,
      );
      expect(find.byType(SourceSwitcher), findsOneWidget);
      final sourceChip = tester.widget<SourceSwitcher>(
        find.byType(SourceSwitcher),
      );
      expect(sourceChip.currentId, 'cs:source_one');
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TvFocusable && widget.semanticLabel == 'cs:source_one',
        ),
        findsOneWidget,
      );
      expect(find.text('Anime One'), findsNothing);
      // The mobile source catalogue promotes its first section to the hero and
      // drops that section from the rows below. TV must do the same or sources
      // whose first section is not named Trending disappear from Home entirely.
      expect(find.text('Source Hero Title'), findsWidgets);

      // The source chip changes this Home-only preference, never the active
      // source used for playback.
      await _changeCatalogue(
        tester,
        () => sourceChip.onChanged('cs:source_two'),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<SourceSwitcher>(find.byType(SourceSwitcher)).currentId,
        'cs:source_two',
      );
      expect(activeSource.state, 'cs:source_one');

      await tester.pumpWidget(const SizedBox.shrink());
      HomeCataloguePrefs.sourceSelection.value = false;
      await activeSource.close();
    },
  );

  testWidgets(
    'TV Stremio tab switches catalogues without changing playback source',
    (tester) async {
      late Directory dir;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('tv_stremio_header');
        Hive.init(dir.path);
        await Hive.openBox(HomeCataloguePrefs.boxName);
        await Hive.openBox(ZModePrefs.boxName);
      });
      final previousRepo = sl.isRegistered<SourceRepository>()
          ? sl<SourceRepository>()
          : null;
      if (previousRepo != null) sl.unregister<SourceRepository>();
      sl.registerSingleton<SourceRepository>(const _StubSourceRepository([]));
      final active = ActiveSourceCubit(fallback: 'cs:unchanged');
      addTearDown(() async {
        sl.unregister<SourceRepository>();
        if (previousRepo != null) {
          sl.registerSingleton<SourceRepository>(previousRepo);
        }
        await active.close();
        await Hive.close();
        await dir.delete(recursive: true);
      });
      await tester.pumpWidget(_homeApp(cubit, activeSource: active));
      await tester.pumpAndSettle();

      Future<void> choose(String key) async {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await _changeCatalogue(tester, () {
          tester.widget<TvFocusable>(find.byKey(ValueKey(key))).onTap();
        });
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byKey(const ValueKey('tv-home-selected-chip')),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('tv-home-selected-chip')),
          findsOneWidget,
        );
        expect(active.state, 'cs:unchanged');
        expect(tester.takeException(), isNull);
      }

      await choose('tv-home-tab-stremio');
      expect(HomeCataloguePrefs.stremioSelected, isTrue);
      expect(find.text('No addons added'), findsOneWidget);
      expect(find.byType(SourceSwitcher), findsNothing);
      await choose('tv-home-tab-source');
      expect(HomeCataloguePrefs.sourceSelected, isTrue);
      await choose('tv-home-tab-stremio');
      await choose('tv-home-tab-anime');
      expect(HomeCataloguePrefs.catalogueKind, HomeCatalogueKind.metadata);
      expect(ZModePrefs.streamKind, StreamKind.anime);
      await choose('tv-home-tab-stremio');
      await choose('tv-home-tab-movie');
      expect(HomeCataloguePrefs.catalogueKind, HomeCatalogueKind.metadata);
      expect(ZModePrefs.streamKind, StreamKind.movie);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('TV home shows local Continue Watching while signed out', (
    tester,
  ) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('tv_continue_history');
      Hive.init(dir.path);
      await WatchHistory.init();
    });
    final history = WatchHistory(SupabaseService(), () => null);
    sl.registerSingleton<WatchHistory>(history);
    await tester.runAsync(
      () => history.save(
        HistoryEntry(
          sourceId: 'test',
          showId: 'local-show',
          showTitle: 'Local Show',
          showUrl: '/local-show',
          category: 'sub',
          episodeId: 'episode-1',
          episodeNumber: 1,
          episodeUrl: '/local-show/1',
          position: const Duration(minutes: 1),
          duration: const Duration(minutes: 24),
          updatedAt: 1,
        ),
      ),
    );

    await tester.pumpWidget(_homeApp(cubit));
    await tester.pumpAndSettle();

    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.text('Local Show'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await Hive.deleteFromDisk();
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    sl.unregister<WatchHistory>();
  });

  testWidgets('repeated Resume presses fetch episodes only once', (
    tester,
  ) async {
    final repo = _BlockingEpisodesRepository(const []);
    sl.unregister<CatalogueRepository>();
    sl.registerSingleton<CatalogueRepository>(repo);
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('tv_resume_guard');
      Hive.init(dir.path);
      await WatchHistory.init();
    });
    final history = WatchHistory(SupabaseService(), () => null);
    sl.registerSingleton<WatchHistory>(history);
    await tester.runAsync(
      () => history.save(
        HistoryEntry(
          sourceId: ZmodeIds.sourceId,
          showId: 'mal:1',
          showTitle: 'Local Show',
          showUrl: 'zm://anime/mal:1',
          category: 'sub',
          episodeId: 'episode-1',
          episodeNumber: 1,
          episodeUrl: 'zm://anime/mal:1/ep/1',
          position: const Duration(minutes: 1),
          duration: const Duration(minutes: 24),
          updatedAt: 1,
        ),
      ),
    );

    await tester.pumpWidget(_homeApp(cubit));
    await tester.pumpAndSettle();
    final resumeCard = tester
        .widgetList<TvFocusable>(find.byType(TvFocusable))
        .firstWhere((f) => f.semanticLabel?.startsWith('Local Show,') ?? false);
    resumeCard.onTap();
    resumeCard.onTap();
    await tester.pump();
    expect(repo.episodeCalls, 1);

    repo.episodesResult.complete(const []);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await Hive.deleteFromDisk();
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    sl.unregister<WatchHistory>();
  });

  testWidgets('TV Continue Watching routes CloudStream entries natively', (
    tester,
  ) async {
    final repo = _BlockingEpisodesRepository(const []);
    sl.unregister<CatalogueRepository>();
    sl.registerSingleton<CatalogueRepository>(repo);
    sl.registerSingleton<SourceRepository>(repo);
    sl.registerSingleton<ProviderManager>(_EmptyProviderManager());
    sl.registerSingleton<ProviderRegistry>(_UnavailableJsRegistry());

    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('tv_resume_cloudstream');
      Hive.init(dir.path);
      await WatchHistory.init();
    });
    final history = WatchHistory(SupabaseService(), () => null);
    sl.registerSingleton<WatchHistory>(history);
    await tester.runAsync(
      () => history.save(
        HistoryEntry(
          sourceId: 'cs:StreamPlay-Anime',
          showId: 'cloudstream-show',
          showTitle: 'CloudStream Show',
          showUrl: 'https://anilist.co/anime/137683',
          category: 'sub',
          episodeId: 'S1E79',
          episodeNumber: 79,
          episodeUrl: 'https://example.com/episode/79',
          position: const Duration(minutes: 1),
          duration: const Duration(minutes: 24),
          updatedAt: 1,
        ),
      ),
    );

    await tester.pumpWidget(_homeApp(cubit));
    await tester.pumpAndSettle();
    final resumeCard = tester
        .widgetList<TvFocusable>(find.byType(TvFocusable))
        .firstWhere(
          (f) => f.semanticLabel?.startsWith('CloudStream Show,') ?? false,
        );
    resumeCard.onTap();
    await tester.pump();

    expect(repo.sourceLoadChecks, ['cs:StreamPlay-Anime']);
    expect(repo.episodeCalls, 1);

    repo.episodesResult.complete(const []);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await Hive.deleteFromDisk();
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    sl.unregister<WatchHistory>();
    sl.unregister<SourceRepository>();
    sl.unregister<ProviderManager>();
    sl.unregister<ProviderRegistry>();
  });

  testWidgets('TV Home does not duplicate metadata repository prefetch', (
    tester,
  ) async {
    final metadata = _WarmMetadataRepository();
    sl.registerSingleton<MetadataRepository>(metadata);

    await tester.pumpWidget(_homeApp(cubit));
    await tester.pumpAndSettle();

    expect(metadata.warmed, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    sl.unregister<MetadataRepository>();
  });

  testWidgets(
    'HomeScreenTv exposes semantics labels for hero buttons, See all and '
    'poster rail items — with no duplicate-text nodes',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_homeApp(cubit));
      await tester.pumpAndSettle();

      // Hero Play / My List / Info buttons each carry their visible label,
      // and read as a focusable button with a tap action. Play autofocuses.
      // The focus action comes from the framework for anything focusable —
      // matchesSemantics asserts every action it isn't told about is absent,
      // so it has to be named here or the whole matcher fails.
      for (final label in ['Play', 'My List', 'Info']) {
        expect(
          tester.getSemantics(find.bySemanticsLabel(label)),
          matchesSemantics(
            label: label,
            isButton: true,
            isFocusable: true,
            isFocused: label == 'Play',
            hasTapAction: true,
            hasFocusAction: true,
          ),
        );
      }

      // Rail poster: the focusable announces the title, and the sibling
      // title Text below it is excluded — only ONE node carries 'Anime Two'
      // (it doesn't collide with the hero's title, which shows 'Anime One').
      expect(
        tester.getSemantics(find.bySemanticsLabel('Anime Two')),
        matchesSemantics(
          label: 'Anime Two',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          hasLongPressAction: true,
          hasFocusAction: true,
        ),
      );

      // Trailing "See all" card.
      expect(find.bySemanticsLabel('See all'), findsOneWidget);

      handle.dispose();
    },
  );

  testWidgets('TV home mounts both catalogues offstage when both are cached', (
    tester,
  ) async {
    if (sl.isRegistered<AppMode>()) sl.unregister<AppMode>();
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));

    const movieItems = [
      MediaItem(
        id: 'm1',
        title: 'Movie One',
        url: '/m1',
        type: ProviderType.movie,
        sourceId: 'test',
      ),
    ];
    cubit.rememberStreamKindRows(StreamKind.anime, [
      const HomeSection(title: 'Trending Now', items: testItems),
    ]);
    cubit.rememberStreamKindRows(StreamKind.movie, [
      const HomeSection(title: 'Trending Movies', items: movieItems),
    ]);

    await tester.pumpWidget(_homeApp(cubit));
    await tester.pump();

    expect(find.byKey(const ValueKey('tv-home-dual-catalog')), findsOneWidget);
    expect(find.byType(IndexedStack), findsNothing);
    expect(find.text('Anime One'), findsWidgets);
    expect(
      find.text('Movie One', skipOffstage: false),
      findsWidgets,
      reason: 'the inactive Movie/TV catalogue must stay mounted offstage',
    );
  });
}
