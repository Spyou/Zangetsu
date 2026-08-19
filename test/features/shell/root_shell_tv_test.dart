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
import 'package:watch_app/core/mode/content_mode_cubit.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_history.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/playback/search_source_prefs.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
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
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/auth/migration_bridge.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';
import 'package:watch_app/features/shell/root_shell_tv.dart';

MigrationBridge _fakeBridge() => MigrationBridge(
      invoke: (_, __) async => const {'ok': false},
      signInPassword: (_, __) async => false,
      verifyOtp: (_, __) async => false,
    );

// ── Minimal fakes (no platform channels, no Hive) ──────────────────────────

/// Fake source repository — all async calls throw, which is caught by
/// HomeCubit / SearchBloc's own try/catch guards. Build-time accessors
/// return safe defaults.
class _FakeSourceRepository implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

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

/// Fake MyListStore — empty list, no Hive box.
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

/// Fake SearchHistory — no Hive box.
class _FakeSearchHistory implements SearchHistory {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<String> recent() => const [];
}

/// Fake SearchPrefs — returns safe defaults, no Hive box.
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

/// Fake SearchSourcePrefs — no excluded sources, no Hive box.
class _FakeSearchSourcePrefs extends ChangeNotifier
    implements SearchSourcePrefs {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Set<String> get excluded => const {};

  @override
  bool isIncluded(String id) => true;
}

/// Fake ProviderRegistry — empty registry, no Hive box.
class _FakeProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => const [];

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;
}

/// Fake tracker — always disconnected, no Hive box.
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

/// Fake DownloadPrefs — always null (default location), no Hive box.
class _FakeDownloadPrefs extends DownloadPrefs {
  @override
  String? get locationUri => null;

  @override
  String? get locationLabel => null;
}

/// [ScheduleScreen] (now a TV rail item — see root_shell_tv.dart) is built
/// eagerly by the IndexedStack and calls these on `..load()`. Override with
/// immediate empty results so no real Dio call happens.
// Non-empty: the ScheduleCubit retries with real backoff timers on an empty
// fetch, and a pending timer would trip the "Timer still pending" teardown.
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

/// [HomeScreen] (rendered inside RootShellTv's shared shell pages) fires a
/// fire-and-forget announcement check on launch. Override to skip Dio + the
/// Hive-backed [AnnouncementStore] entirely — these tests don't care about
/// announcements.
class _FakeAnnouncementService extends AnnouncementService {
  _FakeAnnouncementService() : super(Dio(), AnnouncementStore());
  @override
  Future<List<Announcement>> check() async => const [];
}

// ── Test ───────────────────────────────────────────────────────────────────

void main() {
  late ActiveSourceCubit activeSource;
  late AuthCubit authCubit;

  setUpAll(() {
    // Ensure the test binding is initialised so we can mock platform channels
    // before AppwriteService starts its async Appwrite Client init (which
    // calls getApplicationDocumentsDirectory via path_provider).
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    // Mock path_provider so AppwriteService's async ClientIO init does not
    // throw MissingPluginException across test boundaries.
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );

    // Reset GetIt in case a previous test left registrations.
    await sl.reset();

    // Home's launch sequence shows a one-time community sheet backed by the
    // 'app_flags' Hive box, and SettingsScreen (also rendered via the shared
    // shell pages) reads the accent colour from 'theme_prefs'. Init Hive +
    // mark the sheet seen so those paths no-op / read safe defaults.
    Hive.init('/tmp/zangetsu_root_shell_tv_test_hive');
    final flags = await Hive.openBox('app_flags');
    await flags.put('communitySheetSeen', true);
    await Hive.openBox(ThemeController.boxName);
    // SettingsScreen (rendered eagerly in the shared shell pages) reads
    // sl<PlaybackPrefs>(), which reads its own Hive box — open it first.
    await PlaybackPrefs.init();

    final dio = Dio();
    final fakeRepo = _FakeSourceRepository();
    activeSource = ActiveSourceCubit(); // nullable box → no Hive
    authCubit = AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge()); // cache box is nullable → no Hive

    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<HomeCubit>(HomeCubit(fakeRepo));
    sl.registerSingleton<SourceRepository>(fakeRepo);
    sl.registerSingleton<MyListStore>(_FakeMyListStore());
    sl.registerSingleton<SearchHistory>(_FakeSearchHistory());
    sl.registerSingleton<SearchPrefs>(_FakeSearchPrefs());
    sl.registerSingleton<SearchSourcePrefs>(_FakeSearchSourcePrefs());
    sl.registerSingleton<ListStatusStore>(ListStatusStore());
    sl.registerSingleton<DownloadManager>(DownloadManager(fakeRepo));
    sl.registerSingleton<ProviderRegistry>(_FakeProviderRegistry());
    sl.registerSingleton<AniListService>(_FakeAniListService());
    sl.registerSingleton<MalService>(_FakeMalService());
    sl.registerSingleton<SimklService>(_FakeSimklService());
    sl.registerSingleton<TitleSuggestionService>(TitleSuggestionService(dio));
    sl.registerSingleton<DownloadPrefs>(_FakeDownloadPrefs());
    sl.registerSingleton<AiringService>(_FakeAiringService());
    sl.registerSingleton<ComingSoonService>(_FakeComingSoonService());
    sl.registerSingleton<AnnouncementService>(_FakeAnnouncementService());
    sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
    // Tracker fan-out hub (read by the My List / tracker pages). All three
    // fakes report isConnected == false, so `connected` is empty and every
    // read path safely no-ops — same construction as the injector.
    sl.registerSingleton<TrackerHub>(
      TrackerHub([sl<AniListService>(), sl<MalService>(), sl<SimklService>()]),
    );
    // App-wide content mode (read by Home + Search). Wraps the ActiveSourceCubit
    // above; opens its own tiny 'content_mode' Hive box.
    sl.registerSingleton<ContentModeCubit>(
      await ContentModeCubit.create(activeSource),
    );
  });

  tearDown(() async {
    // Clear the path_provider mock so it doesn't bleed into other test files.
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await sl.reset();
    authCubit.close();
    activeSource.close();
    await Hive.close();
  });

  testWidgets(
    'RootShellTv shows a focusable nav rail with the destinations',
    (tester) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: activeSource),
            BlocProvider<AuthCubit>.value(value: authCubit),
          ],
          child: const MaterialApp(home: RootShellTv()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    },
  );

  testWidgets(
    'RootShellTv shows the profile row at the top of the nav',
    (tester) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: activeSource),
            BlocProvider<AuthCubit>.value(value: authCubit),
          ],
          child: const MaterialApp(home: RootShellTv()),
        ),
      );
      await tester.pumpAndSettle();
      // The account/profile row (avatar + name / "Sign in") is keyed
      // 'tv-nav-avatar' and sits at the top of the nav.
      expect(find.byKey(const ValueKey('tv-nav-avatar')), findsOneWidget);
    },
  );

  testWidgets(
    'RootShellTv shows a source indicator in the rail',
    (tester) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: activeSource),
            BlocProvider<AuthCubit>.value(value: authCubit),
          ],
          child: const MaterialApp(home: RootShellTv()),
        ),
      );
      await tester.pumpAndSettle();
      // The source indicator is keyed 'tv-source-indicator' — exactly one
      // in the rail. The swap_horiz icon is only on this row.
      expect(
        find.byKey(const ValueKey('tv-source-indicator')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.swap_horiz_rounded), findsOneWidget);
    },
  );

  testWidgets(
    'RootShellTv has exactly two Focus zones (rail scope + content scope)',
    (tester) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: activeSource),
            BlocProvider<AuthCubit>.value(value: authCubit),
          ],
          child: const MaterialApp(home: RootShellTv()),
        ),
      );
      await tester.pumpAndSettle();

      // The two explicit FocusScopeNodes are attached to Focus widgets whose
      // debug labels start with 'tv-'.  Verify both are in the focus tree by
      // checking that the tree contains at least those two labelled scope nodes.
      final scopeNodes = <FocusScopeNode>[];
      void visitScope(FocusNode node) {
        if (node is FocusScopeNode &&
            (node.debugLabel ?? '').startsWith('tv-')) {
          scopeNodes.add(node);
        }
        for (final child in node.children) {
          visitScope(child);
        }
      }

      visitScope(tester.binding.focusManager.rootScope);
      // Expect exactly the rail scope and the content scope.
      expect(
        scopeNodes.map((n) => n.debugLabel).toSet(),
        containsAll(['tv-rail-scope', 'tv-content-scope']),
      );
    },
  );

  // ── Back-to-exit tests ─────────────────────────────────────────────────────

  testWidgets(
    'RootShellTv has a PopScope(canPop: false) wrapping the shell',
    (tester) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: activeSource),
            BlocProvider<AuthCubit>.value(value: authCubit),
          ],
          child: const MaterialApp(home: RootShellTv()),
        ),
      );
      await tester.pumpAndSettle();
      // PopScope with canPop: false must be present so Back is never handled
      // by the default Navigator but always by our custom handler.
      final popScopes = tester.widgetList<PopScope>(find.byType(PopScope));
      expect(
        popScopes.any((ps) => ps.canPop == false),
        isTrue,
        reason: 'Expected a PopScope(canPop: false) in the RootShellTv tree',
      );
    },
  );

  testWidgets(
    'RootShellTv: first Back on the Home tab shows the exit snackbar',
    (tester) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: activeSource),
            BlocProvider<AuthCubit>.value(value: authCubit),
          ],
          child: const MaterialApp(home: RootShellTv()),
        ),
      );
      await tester.pumpAndSettle();

      // RootShellTv starts on the Home tab (index 0).  The first Back should
      // NOT exit the app — it should show a snackbar instead.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // Snackbar must appear.
      expect(find.text('Press back again to exit'), findsOneWidget);

      // RootShellTv must still be in the widget tree (no pop occurred).
      expect(find.byType(RootShellTv), findsOneWidget);
    },
  );

  testWidgets(
    'RootShellTv nav items expose their visible label as the semantics label',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: activeSource),
            BlocProvider<AuthCubit>.value(value: authCubit),
          ],
          child: const MaterialApp(home: RootShellTv()),
        ),
      );
      await tester.pumpAndSettle();

      // Home's nav item wraps the 'Home' Text — its TvFocusable ancestor
      // should carry 'Home' as the TalkBack name.
      final homeFocusable = find.ancestor(
        of: find.text('Home'),
        matching: find.byType(TvFocusable),
      );
      expect(
        tester.getSemantics(homeFocusable),
        matchesSemantics(
          label: 'Home',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          // Framework-supplied for anything focusable; matchesSemantics fails
          // on any action it wasn't told to expect.
          hasFocusAction: true,
        ),
      );
      // ...and only ONE node in the tree carries 'Home' — the label Text
      // inside the item must be excluded, or TalkBack announces it twice.
      expect(find.bySemanticsLabel('Home'), findsOneWidget);

      handle.dispose();
    },
  );

  // ── rail/content D-pad bridge handlers ────────────────────────────────────
  //
  // _onRailKey / _onContentKey bridge focus between the rail and the content
  // scope on LEFT/RIGHT. This bridge is deliberately NOT gated on
  // MediaQuery.accessibleNavigation: Fire TV / onn falsely report that flag
  // true after returning from the native player Activity even with no screen
  // reader running, and the old gate silently dead-keyed the D-pad in that
  // state (the drawer became impossible to open until an app restart). So the
  // arrows bridge rail ↔ content the same way whether accessibleNavigation is
  // off (the default, sighted user) or on.

  testWidgets(
    'RootShellTv rail/content handlers: arrows bridge rail ↔ content when '
    'a screen reader is OFF (sighted user, original behaviour)',
    (tester) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: activeSource),
            BlocProvider<AuthCubit>.value(value: authCubit),
          ],
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(accessibleNavigation: false),
              child: const RootShellTv(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Search — its field always autofocuses regardless of data,
      // giving content a reliable focus target (Home's content is empty in
      // this fixture since the fake repo throws).
      tester
          .widget<TvFocusable>(
            find.ancestor(
              of: find.text('Search'),
              matching: find.byType(TvFocusable),
            ),
          )
          .onTap();
      await tester.pumpAndSettle();

      final fieldFocus = tester.binding.focusManager.primaryFocus;
      expect(fieldFocus, isNotNull);
      expect(fieldFocus?.nearestScope?.debugLabel, 'tv-content-scope');

      // arrowLeft → _onContentKey drops back onto the current page's rail
      // item once intra-content traversal is exhausted (ORIGINAL behaviour).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        tester.binding.focusManager.primaryFocus?.nearestScope?.debugLabel,
        'tv-rail-scope',
      );

      // arrowRight → _onRailKey hands focus back to the last-focused content
      // child (ORIGINAL behaviour).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(tester.binding.focusManager.primaryFocus, same(fieldFocus));
    },
  );

  testWidgets(
    'RootShellTv rail/content handlers: arrows STILL bridge rail ↔ content when '
    'a screen reader is ON (accessibleNavigation no longer gates the bridge)',
    (tester) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<ActiveSourceCubit>.value(value: activeSource),
            BlocProvider<AuthCubit>.value(value: authCubit),
          ],
          child: MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(accessibleNavigation: true),
              child: const RootShellTv(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Search — its field always autofocuses regardless of data,
      // giving content a reliable focus target (Home's content is empty in
      // this fixture since the fake repo throws).
      tester
          .widget<TvFocusable>(
            find.ancestor(
              of: find.text('Search'),
              matching: find.byType(TvFocusable),
            ),
          )
          .onTap();
      await tester.pumpAndSettle();

      final fieldFocus = tester.binding.focusManager.primaryFocus;
      expect(fieldFocus, isNotNull);
      expect(fieldFocus?.nearestScope?.debugLabel, 'tv-content-scope');

      // arrowLeft → _onContentKey drops back onto the current page's rail item
      // even with accessibleNavigation ON (the gate that used to ignore this
      // was removed — see commits 1ef97f8 / b6aa99c).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        tester.binding.focusManager.primaryFocus?.nearestScope?.debugLabel,
        'tv-rail-scope',
      );

      // arrowRight → _onRailKey hands focus back to the last-focused content
      // child — also fires with a screen reader ON.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(tester.binding.focusManager.primaryFocus, same(fieldFocus));
    },
  );
}
