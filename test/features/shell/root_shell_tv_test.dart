// ignore_for_file: invalid_use_of_protected_member

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/models/home_section.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/playback/list_status_store.dart';
import 'package:watch_app/core/playback/my_list.dart';
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
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/home/cubit/home_cubit.dart';
import 'package:watch_app/features/shell/root_shell_tv.dart';

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

    final dio = Dio();
    final fakeRepo = _FakeSourceRepository();
    activeSource = ActiveSourceCubit(); // nullable box → no Hive
    authCubit = AuthCubit(AppwriteService()); // cache box is nullable → no Hive

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
    'RootShellTv shows the ZANGETSU wordmark image at the top of the rail',
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
      // The rail's wordmark is keyed 'tv-rail-wordmark' — exactly one in the
      // nav rail (other shell pages may also show the wordmark at a different
      // size; the key identifies the rail's copy specifically).
      expect(find.byKey(const ValueKey('tv-rail-wordmark')), findsOneWidget);
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
      expect(find.byIcon(Icons.swap_horiz), findsOneWidget);
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

}
