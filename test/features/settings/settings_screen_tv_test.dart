// TV settings hub shares [SettingsScreen] with mobile (AppMode.isTv).
//
// Features restored after the z-mode merge (097192ba) that dropped them from
// the old flat TV list — now reachable via the unified section drill-down:
//
//   Sync library to cloud — boot sync only seeds and PULLS
//   Watch History — History category opens HistoryScreen directly
//   Auto-update extensions — Android-only, gated with CloudStream toggles
//
// STILL OWED elsewhere:
//   root_shell_tv.dart  active-source pill in the nav rail
//   home_screen_tv.dart tracker rails (deleted home_screen_tv_tracker.dart)

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/appwrite/appwrite_service.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/core/locale/locale_controller.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/torrent/torrent_prefs.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/core/tv/tv_list_focusable.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/auth/migration_bridge.dart';
import 'package:watch_app/features/settings/settings_screen.dart';
import 'package:watch_app/l10n/app_localizations.dart';

MigrationBridge _fakeBridge() => MigrationBridge(
      invoke: (_, __) async => const {'ok': false},
      signInPassword: (_, __) async => false,
      verifyOtp: (_, __) async => false,
    );

// ── Minimal stubs ─────────────────────────────────────────────────────────────

class _StubSearchPrefs extends SearchPrefs {
  @override
  SearchLayout get layout => SearchLayout.vertical;
}

class _StubProviderRegistry implements ProviderRegistry {
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);

  @override
  List<ProviderRegistryEntry> getAll() => const [];

  @override
  ProviderRegistryEntry? entryFor(String sourceId) => null;

  @override
  Set<String> nsfwSourceIds() => const {};
}

class _StubAniList implements AniListService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubMal implements MalService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _StubSimkl implements SimklService {
  @override
  bool get isConnected => false;
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Registers the GetIt singletons needed for [SettingsScreen] with [AppMode.isTv].
Future<void> _registerStubs() async {
  await Hive.openBox(PlaybackPrefs.boxName);
  await Hive.openBox(DownloadPrefs.boxName);
  await Hive.openBox(TorrentPrefs.boxName);
  await Hive.openBox(ThemeController.boxName);
  await ReaderPrefs.init();
  final sl = GetIt.instance;
  sl
    ..registerSingleton<AppMode>(const AppMode(isTv: true))
    ..registerSingleton<SearchPrefs>(_StubSearchPrefs())
    ..registerSingleton<ProviderRegistry>(_StubProviderRegistry())
    ..registerSingleton<AniListService>(_StubAniList())
    ..registerSingleton<MalService>(_StubMal())
    ..registerSingleton<SimklService>(_StubSimkl())
    ..registerSingleton<PlaybackPrefs>(PlaybackPrefs())
    ..registerSingleton<DownloadPrefs>(DownloadPrefs())
    ..registerSingleton<TorrentPrefs>(TorrentPrefs())
    ..registerSingleton<ReaderPrefs>(ReaderPrefs());
}

void _mockPathProvider(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => '/tmp/test',
  );
}

Widget _buildUnderTest({
  required AuthCubit authCubit,
  required ActiveSourceCubit activeCubit,
}) =>
    MultiBlocProvider(
      providers: [
        BlocProvider<AuthCubit>.value(value: authCubit),
        BlocProvider<ActiveSourceCubit>.value(value: activeCubit),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SettingsScreen(),
      ),
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late ActiveSourceCubit activeCubit;
  late Directory hiveDir;

  setUp(() async {
    hiveDir = await Directory.systemTemp.createTemp('settings_tv_test');
    Hive.init(hiveDir.path);
    await Hive.openBox(LocaleController.boxName);
    await LocaleController.init();
    await _registerStubs();
    activeCubit = ActiveSourceCubit();
  });

  tearDown(() async {
    await activeCubit.close();
    await GetIt.instance.reset();
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  testWidgets(
    'TV SettingsScreen shows Sign-in tile when unauthenticated',
    (tester) async {
      _mockPathProvider(tester);
      final authCubit =
          AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);

      await tester.pumpWidget(
        _buildUnderTest(authCubit: authCubit, activeCubit: activeCubit),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Profile'), findsNothing);
    },
  );

  testWidgets(
    'TV SettingsScreen shows section categories like mobile',
    (tester) async {
      _mockPathProvider(tester);
      await tester.binding.setSurfaceSize(const Size(1280, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final authCubit =
          AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);

      await tester.pumpWidget(
        _buildUnderTest(authCubit: authCubit, activeCubit: activeCubit),
      );
      await tester.pumpAndSettle();

      for (final section in const [
        'Account & sync',
        'Sources',
        'Playback',
        'Downloads',
        'Interface',
        'Advanced',
        'About',
      ]) {
        expect(find.text(section), findsOneWidget, reason: 'category: $section');
      }
      // History is a single-destination section — category title is History.
      expect(find.text('History'), findsOneWidget);
      // Manga/novel reader and search are phone-only.
      expect(find.text('Reading'), findsNothing);
      expect(find.text('Reader'), findsNothing);
      expect(find.text('Search settings'), findsNothing);
      // Leaf tiles live inside sections, not on the root.
      expect(find.text('Providers'), findsNothing);
      expect(find.text('Backup & Restore'), findsNothing);
    },
  );

  testWidgets(
    'TV SettingsScreen History category is D-pad reachable',
    (tester) async {
      _mockPathProvider(tester);
      final authCubit =
          AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);

      await tester.pumpWidget(
        _buildUnderTest(authCubit: authCubit, activeCubit: activeCubit),
      );
      await tester.pumpAndSettle();

      expect(find.text('History'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('History'),
          matching: find.byType(TvListFocusable),
        ),
        findsOneWidget,
      );
      expect(Platform.isAndroid, isFalse, reason: 'Android-only tiles gated');
    },
  );

  testWidgets(
    'TV SettingsScreen offers sync library inside Account & sync',
    (tester) async {
      _mockPathProvider(tester);
      await tester.binding.setSurfaceSize(const Size(1280, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final authCubit =
          AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);

      await tester.pumpWidget(
        _buildUnderTest(authCubit: authCubit, activeCubit: activeCubit),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Account & sync'));
      await tester.pumpAndSettle();

      expect(find.text('Sync library to cloud'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.text('Sync library to cloud'),
          matching: find.byType(TvListFocusable),
        ),
        findsOneWidget,
      );
      expect(find.text('Backup & Restore'), findsOneWidget);
    },
  );

  testWidgets(
    'TV SettingsScreen only the first TvFocusable has autofocus=true',
    (tester) async {
      _mockPathProvider(tester);
      final authCubit =
          AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);

      await tester.pumpWidget(
        _buildUnderTest(authCubit: authCubit, activeCubit: activeCubit),
      );
      await tester.pumpAndSettle();

      final focusables =
          tester.widgetList<TvFocusable>(find.byType(TvFocusable)).toList();

      expect(focusables, isNotEmpty);
      expect(focusables.first.autofocus, isTrue);
      for (final f in focusables.skip(1)) {
        expect(f.autofocus, isFalse);
      }
    },
  );

  testWidgets(
    'TV SettingsScreen category tiles carry a semanticLabel for TalkBack',
    (tester) async {
      _mockPathProvider(tester);
      await tester.binding.setSurfaceSize(const Size(1280, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final authCubit =
          AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
      addTearDown(authCubit.close);

      await tester.pumpWidget(
        _buildUnderTest(authCubit: authCubit, activeCubit: activeCubit),
      );
      await tester.pumpAndSettle();

      // SettingsTile wraps TV rows in TvListFocusable(semanticLabel: title) with
      // ExcludeSemantics on the visual child — one labeled node per row.
      final historyFocusable = tester.widget<TvListFocusable>(
        find.ancestor(
          of: find.text('History'),
          matching: find.byType(TvListFocusable),
        ),
      );
      expect(historyFocusable.semanticLabel, 'History');
    },
  );
}
