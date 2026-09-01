// ignore_for_file: invalid_use_of_protected_member

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/announce/announcement.dart';
import 'package:watch_app/core/announce/announcement_service.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/repository/catalogue_repository.dart';
import 'package:watch_app/core/repository/source_repository.dart';
import 'package:watch_app/core/schedule/airing_service.dart';
import 'package:watch_app/core/schedule/coming_soon_service.dart';
import 'package:watch_app/core/schedule/schedule_models.dart';
import 'package:watch_app/core/search/title_suggestion_service.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/core/tracker/tracker_hub.dart';
import 'package:watch_app/core/download/chapter_download_store.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/auth/migration_bridge.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';
import 'package:watch_app/features/home/home_screen.dart';
import 'package:watch_app/features/shell/root_shell.dart';
import 'package:watch_app/features/shell/root_shell_tv.dart';

MigrationBridge _fakeBridge() => MigrationBridge(
  invoke: (_, __) async => const {'ok': false},
  signInPassword: (_, __) async => false,
  verifyOtp: (_, __) async => false,
);

// ── Minimal fakes (same shape as root_shell_tv_test.dart's harness) ────────

class _FakeSourceRepository implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
  @override
  List<({String id, String name})> get pickableSources => loadedSources;

  @override
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async =>
      throw UnimplementedError('_FakeSourceRepository.home — caught upstream');

  @override
  String displayName(String sourceId) => sourceId;

  @override
  String get sourceId => 'allanime';

  @override
  List<({String id, String name})> get loadedSources => const [];

  @override
  bool hasSource(String sourceId) => false;
}

class _FakeMyListStore implements MyListStore {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<MediaItem> all() => const [];

  @override
  bool contains(MediaItem m) => false;

  @override
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
}

class _FakeSearchHistory implements SearchHistory {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<String> recent() => const [];
}

class _FakeSearchPrefs extends ChangeNotifier implements SearchPrefs {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  SearchLayout get layout => SearchLayout.vertical;

  @override
  String? get contentFilterName => null;

  @override
  String? get audioFilterName => null;

  @override
  String? get statusFilterName => null;

  @override
  String? get sortName => null;

  @override
  String? get genre => null;

  @override
  int? get decade => null;

  @override
  bool get currentSourceOnly => true;
}

class _FakeSearchSourcePrefs extends ChangeNotifier
    implements SearchSourcePrefs {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Set<String> get excluded => const {};

  @override
  bool isIncluded(String id) => true;
}

class _FakeProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => const [];

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;

  @override
  Set<String> nsfwSourceIds() => const {};

  @override
  Map<String, String> typeMapOf() => const {};
}

class _FakeAniListService extends ChangeNotifier implements AniListService {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool get isConnected => false;

  @override
  String get displayName => 'AniList';

  @override
  String? get viewerName => null;

  @override
  String? get viewerAvatar => null;
}

class _FakeMalService extends ChangeNotifier implements MalService {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool get isConnected => false;

  @override
  String get displayName => 'MyAnimeList';

  @override
  String? get viewerName => null;

  @override
  String? get viewerAvatar => null;
}

class _FakeSimklService extends ChangeNotifier implements SimklService {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  bool get isConnected => false;

  @override
  String get displayName => 'Simkl';

  @override
  String? get viewerName => null;

  @override
  String? get viewerAvatar => null;
}

class _FakeDownloadPrefs extends DownloadPrefs {
  @override
  String? get locationUri => null;

  @override
  String? get locationLabel => null;
}

/// [ScheduleScreen] (built eagerly by both shells' IndexedStack) creates a
/// ScheduleCubit that calls these on `..load()`. Override with immediate
/// empty results so no real Dio call happens — the nav test only cares that
/// the destination exists, not what it renders.
// Return one entry (not empty): the ScheduleCubit now retries with real
// backoff timers when a fetch comes back empty, and a pending timer would
// trip the "Timer still pending" teardown check. The nav test only cares
// that the destination exists, so any non-empty result is fine.
class _FakeAiringService extends AiringService {
  _FakeAiringService() : super(Dio());
  @override
  Future<List<AiringEntry>> weekAiring({DateTime? now}) async => [
    AiringEntry(
      malId: 1,
      title: 'x',
      coverUrl: null,
      episode: 1,
      airsAtLocal: DateTime(2026),
      format: 'TV',
    ),
  ];
}

class _FakeComingSoonService extends ComingSoonService {
  _FakeComingSoonService() : super(Dio());
  @override
  Future<List<ComingSoonEntry>> upcoming() async => const [
    ComingSoonEntry(
      tmdbId: 1,
      isTv: false,
      title: 'x',
      posterUrl: null,
      releaseDate: null,
    ),
  ];
}

/// [HomeScreen] fires a fire-and-forget announcement check on launch (see
/// [maybeShowAnnouncement]). Override to skip Dio + the Hive-backed
/// [AnnouncementStore] entirely — nav tests don't care about announcements.
class _FakeAnnouncementService extends AnnouncementService {
  _FakeAnnouncementService() : super(Dio(), AnnouncementStore());
  @override
  Future<List<Announcement>> check() async => const [];
}

// ── Test ─────────────────────────────────────────────────────────────────

void main() {
  late ActiveSourceCubit activeSource;
  late AuthCubit authCubit;
  late ContentModeCubit contentMode;

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

    // Home's launch sequence shows a one-time community sheet backed by the
    // 'app_flags' Hive box. Init Hive + mark it seen so that path no-ops
    // (mirrors production, where Hive is initialized before runApp).
    Hive.init('/tmp/zangetsu_nav_test_hive');
    final flags = await Hive.openBox('app_flags');
    await flags.put('communitySheetSeen', true);
    await Hive.openBox(ThemeController.boxName);
    // Home's initState fires a delayed (4s) source-update check that reads
    // PlaybackPrefs — pumpAndSettle fast-forwards fake time straight through
    // that delay, so it needs to be registered even though this test never
    // waits on it directly. MyListScreen's header similarly needs a TrackerHub
    // (IndexedStack builds every tab eagerly, TrackerHub included).
    await Hive.openBox(PlaybackPrefs.boxName);

    final dio = Dio();
    final fakeRepo = _FakeSourceRepository();
    activeSource = ActiveSourceCubit();
    authCubit = AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
    // This suite reuses a fixed on-disk Hive dir (not a fresh temp dir) across
    // runs, so a mode persisted by an earlier run would otherwise leak in here
    // and start tests in the wrong mode.
    await Hive.deleteBoxFromDisk('content_mode');
    contentMode = await ContentModeCubit.create(activeSource);
    // Same leak-prevention as content_mode above, so the toggle starts off
    // (its default) in every test regardless of run order.
    await Hive.deleteBoxFromDisk(ZModePrefs.boxName);
    await ZModePrefs.init();
    // Both paths are covered here, so start from off and let the Z Mode
    // cases opt in — it is on by default since the toggle was removed.
    await ZModePrefs.setEnabled(false);
    // The dock builds every tab's screen into an IndexedStack, and Downloads
    // is a default tab now — so DownloadsScreen is constructed by every test
    // here and needs its store, whether or not the test looks at it.
    await ChapterDownloadStore.init();
    if (!sl.isRegistered<ChapterDownloadStore>()) {
      sl.registerSingleton<ChapterDownloadStore>(ChapterDownloadStore());
    }

    sl.registerSingleton<HomeCubit>(HomeCubit(fakeRepo));
    sl.registerSingleton<ContentModeCubit>(contentMode);
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    sl.registerSingleton<TrackerHub>(TrackerHub(const []));
    sl.registerSingleton<SourceRepository>(fakeRepo);
    sl.registerSingleton<CatalogueRepository>(fakeRepo);
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<SearchHistory>(_FakeSearchHistory());
    sl.registerSingleton<SearchPrefs>(_FakeSearchPrefs());
    sl.registerSingleton<SearchSourcePrefs>(_FakeSearchSourcePrefs());
    sl.registerSingleton<ListStatusStore>(ListStatusStore());
    sl.registerSingleton<DownloadManager>(DownloadManager(fakeRepo));
    sl.registerSingleton<ProviderRegistry>(_FakeProviderRegistry());
    sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
    sl.registerSingleton<AniyomiManager>(AniyomiManager());
    sl.registerSingleton<AniListService>(_FakeAniListService());
    sl.registerSingleton<MalService>(_FakeMalService());
    sl.registerSingleton<SimklService>(_FakeSimklService());
    sl.registerSingleton<TitleSuggestionService>(TitleSuggestionService(dio));
    sl.registerSingleton<DownloadPrefs>(_FakeDownloadPrefs());
    sl.registerSingleton<AiringService>(_FakeAiringService());
    sl.registerSingleton<ComingSoonService>(_FakeComingSoonService());
    sl.registerSingleton<AnnouncementService>(_FakeAnnouncementService());
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await sl.reset();
    authCubit.close();
    activeSource.close();
    await contentMode.close();
    await Hive.close();
  });

  Widget wrap(Widget child) => MultiBlocProvider(
    providers: [
      BlocProvider<ActiveSourceCubit>.value(value: activeSource),
      BlocProvider<AuthCubit>.value(value: authCubit),
    ],
    child: MaterialApp(home: child),
  );

  // Home now has its own Schedule card (Anime mode only, same label as the
  // dock tab — task 11), so a bare `find.text('Schedule')` can match either
  // one while Home is the visible tab. The floating dock is the only widget
  // in this tree wrapped in `AnimatedSlide`, so scoping through it isolates
  // the dock tab specifically.
  Finder dockLabel(String label) => find.descendant(
    of: find.byType(AnimatedSlide),
    matching: find.text(label),
  );

  // Schedule left the dock for the card row on Home, beside the Manga/Novel
  // mode cards — two doors to one screen was the point of removing it — and
  // Downloads took the slot it left.
  testWidgets('the phone dock swapped Schedule for Downloads', (
    tester,
  ) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    await tester.pumpWidget(wrap(const RootShell()));
    await tester.pumpAndSettle();

    expect(dockLabel('Schedule'), findsNothing);
    expect(dockLabel('Downloads'), findsOneWidget);
  });

  // Task 17: Search moved from the dock to the Home header (HomeSearchAction
  // — see home_search_action_test.dart). The dock itself should never offer
  // it, on the default tab set the app actually ships.
  testWidgets('the dock never offers a Search tab', (tester) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    await tester.pumpWidget(wrap(const RootShell()));
    await tester.pumpAndSettle();

    expect(dockLabel('Search'), findsNothing);
  });

  testWidgets('TV shell keeps Downloads and gains a Schedule rail item', (
    tester,
  ) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    await tester.pumpWidget(wrap(const RootShellTv()));
    await tester.pumpAndSettle();

    // This fixture has zero loaded sources, so Home's initial focus lands on
    // its own "no sources yet" Browse button rather than the rail — the rail
    // only shows its text labels once expanded. LEFT from content opens it,
    // same bridge root_shell_tv_test.dart exercises directly.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();

    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
  });

  // Home's mode-cards row carries the Schedule card alongside the Manga/Novel
  // switcher cards. Since Schedule left the dock this is the ONLY way in, so
  // this test is now load-bearing rather than a second opinion. Anime mode
  // only — Schedule has nothing to say in a reading mode.
  // Schedule now lives behind the hub card rather than a card of its own, so
  // the guarantee got stronger: it is reachable from every mode instead of
  // vanishing in Manga and Novel the way the old Schedule card did.
  testWidgets("Home's hub card shows in every mode", (tester) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    await tester.pumpWidget(wrap(const RootShell()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('home_lists_hub_card')), findsOneWidget);

    for (final m in ContentMode.values) {
      await tester.runAsync(() => contentMode.setMode(m));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('home_lists_hub_card')),
        findsOneWidget,
        reason: 'Schedule has no other entry point in $m',
      );
    }
  });

  // The row used to be hidden entirely under Z Mode (`if (!ZModePrefs.enabled)`),
  // which was survivable while Schedule also had a dock tab. It doesn't, so the
  // card has to be there in BOTH modes or Schedule has no entry point at all.
  // The hub label is a phrase, not a word, which is why it gets twice the width
  // of a switcher. On the narrowest phone we support that is still three cards
  // sharing one row, so pin the case that would ellipsise or overflow it.
  testWidgets('the card row survives a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    await tester.pumpWidget(wrap(const RootShell()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('home_lists_hub_card')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home keeps the hub card with Z Mode on', (tester) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    await tester.pumpWidget(wrap(const RootShell()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home_lists_hub_card')), findsOneWidget);

    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home_lists_hub_card')), findsOneWidget);

    await tester.runAsync(() => ZModePrefs.setEnabled(false));
    await tester.pumpAndSettle();
  });

  // Task 11 added a full-width "Search" bar to Home while Z Mode was on
  // (Search having left the dock); task 17 replaced that with a header icon
  // instead (HomeBrowseSourcesAction's sibling, HomeSearchAction — covered by
  // home_search_action_test.dart), shown regardless of Z Mode. So this no
  // longer asserts the search icon is absent — that icon is legitimate now —
  // only that task 11's specific full-width caption bar never comes back.
  // Pumped as bare HomeScreen, not the full RootShell: the shell's
  // IndexedStack also mounts SearchScreen (offstage), whose SearchScope stays
  // reactive to ZModePrefs.revision even offstage and would need a real
  // MetadataRepository the moment Z Mode flips on — nothing this test cares
  // about.
  testWidgets("Home doesn't bring back the old full-width search bar", (
    tester,
  ) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    await tester.pumpWidget(wrap(const HomeScreen()));
    await tester.pumpAndSettle();

    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    await tester.pumpAndSettle();

    // The old bar's tell was a caption reading "Search" beside its icon; the
    // header's icon-only action has a tooltip (not rendered as Text) instead.
    expect(find.text('Search'), findsNothing);
  });
}
