// ignore_for_file: invalid_use_of_protected_member

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/announce/announcement.dart';
import 'package:watch_app/core/announce/announcement_service.dart';
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
import 'package:watch_app/features/shell/root_shell.dart';
import 'package:watch_app/features/shell/root_shell_tv.dart';

// ── Minimal fakes (same shape as root_shell_tv_test.dart's harness) ────────

class _FakeSourceRepository implements SourceRepository {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) async =>
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
  String? get sortName => null;

  @override
  String? get genre => null;

  @override
  int? get decade => null;

  @override
  bool get currentSourceOnly => true;
}

class _FakeSearchSourcePrefs extends ChangeNotifier implements SearchSourcePrefs {
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
class _FakeAiringService extends AiringService {
  _FakeAiringService() : super(Dio());
  @override
  Future<List<AiringEntry>> weekAiring({DateTime? now}) async => const [];
}

class _FakeComingSoonService extends ComingSoonService {
  _FakeComingSoonService() : super(Dio());
  @override
  Future<List<ComingSoonEntry>> upcoming() async => const [];
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

    final dio = Dio();
    final fakeRepo = _FakeSourceRepository();
    activeSource = ActiveSourceCubit();
    authCubit = AuthCubit(AppwriteService());

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
  });

  Widget wrap(Widget child) => MultiBlocProvider(
        providers: [
          BlocProvider<ActiveSourceCubit>.value(value: activeSource),
          BlocProvider<AuthCubit>.value(value: authCubit),
        ],
        child: MaterialApp(home: child),
      );

  testWidgets('phone shell shows a Schedule destination and no Downloads',
      (tester) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    await tester.pumpWidget(wrap(const RootShell()));
    await tester.pumpAndSettle();

    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Downloads'), findsNothing);
  });

  testWidgets('TV shell keeps Downloads and gains a Schedule rail item',
      (tester) async {
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    await tester.pumpWidget(wrap(const RootShellTv()));
    await tester.pumpAndSettle();

    expect(find.text('Downloads'), findsOneWidget);
    expect(find.text('Schedule'), findsOneWidget);
  });
}
