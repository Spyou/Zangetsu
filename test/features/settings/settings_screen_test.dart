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
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/core/torrent/torrent_prefs.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/supabase/supabase_service.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/auth/migration_bridge.dart';
import 'package:watch_app/features/settings/settings_screen.dart';

MigrationBridge _fakeBridge() => MigrationBridge(
      invoke: (_, __) async => const {'ok': false},
      signInPassword: (_, __) async => false,
      verifyOtp: (_, __) async => false,
    );

// ── Minimal stubs (mirrors settings_screen_tv_test.dart) ─────────────────────

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

void _mockPathProvider(WidgetTester tester) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => '/tmp/test',
  );
}

void main() {
  late ActiveSourceCubit activeCubit;
  late Directory _hiveDir;

  setUp(() async {
    _hiveDir = await Directory.systemTemp.createTemp();
    Hive.init(_hiveDir.path);
    await Hive.openBox(DownloadPrefs.boxName);
    await Hive.openBox(TorrentPrefs.boxName);
    await Hive.openBox(ThemeController.boxName);
    await Hive.openBox(PlaybackPrefs.boxName);
    await ReaderPrefs.init();
    final sl = GetIt.instance;
    sl
      ..registerSingleton<AppMode>(AppMode(isTv: false))
      ..registerSingleton<SearchPrefs>(_StubSearchPrefs())
      ..registerSingleton<ProviderRegistry>(_StubProviderRegistry())
      ..registerSingleton<AniListService>(_StubAniList())
      ..registerSingleton<MalService>(_StubMal())
      ..registerSingleton<SimklService>(_StubSimkl())
      ..registerSingleton<PlaybackPrefs>(PlaybackPrefs())
      ..registerSingleton<DownloadPrefs>(DownloadPrefs())
      ..registerSingleton<TorrentPrefs>(TorrentPrefs())
      ..registerSingleton<ReaderPrefs>(ReaderPrefs());
    activeCubit = ActiveSourceCubit();
  });

  tearDown(() async {
    await activeCubit.close();
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (_hiveDir.existsSync()) await _hiveDir.delete(recursive: true);
  });

  Future<void> _pumpSettings(WidgetTester tester) async {
    _mockPathProvider(tester);
    await tester.binding.setSurfaceSize(const Size(1000, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final authCubit =
        AuthCubit(SupabaseService(), AppwriteService(), _fakeBridge());
    addTearDown(authCubit.close);
    GetIt.instance.registerSingleton<AuthCubit>(authCubit);

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthCubit>.value(value: authCubit),
          BlocProvider<ActiveSourceCubit>.value(value: activeCubit),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('top level shows one tappable row per section, not the tiles',
      (tester) async {
    await _pumpSettings(tester);

    // Each section is now a single drill-down row.
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
    // Notifications is Android-only (its sole entry), so its category is absent
    // on the non-Android test host.
    expect(find.text('Notifications'), findsNothing);
    // The individual settings live INSIDE their section now, not up top.
    expect(find.text('Providers'), findsNothing);
    expect(find.text('Storage'), findsNothing);
    expect(find.text('Backup & Restore'), findsNothing);
  });

  testWidgets('tapping a category drills into its settings', (tester) async {
    await _pumpSettings(tester);

    await tester.tap(find.text('Sources'));
    await tester.pumpAndSettle();

    // The Sources section's tiles are now on screen.
    for (final t in const ['Providers', 'Active source', 'Source health']) {
      expect(find.text(t), findsOneWidget, reason: 'tile: $t');
    }
    // Other sections' rows are gone (we're on the Sources sub-page).
    expect(find.text('Downloads'), findsNothing);
    expect(find.text('About'), findsNothing);
  });

  testWidgets('Playback section has a Reader entry that opens reader defaults',
      (tester) async {
    await _pumpSettings(tester);

    await tester.tap(find.text('Playback'));
    await tester.pumpAndSettle();
    expect(find.text('Reader'), findsOneWidget);

    await tester.tap(find.text('Reader'));
    await tester.pumpAndSettle();

    expect(find.text('MANGA DEFAULTS'), findsOneWidget);
    expect(find.text('NOVEL DEFAULTS'), findsOneWidget);
  });

  testWidgets('search cuts across every section (flat filtered list)',
      (tester) async {
    await _pumpSettings(tester);

    await tester.enterText(find.byType(TextField), 'backup');
    await tester.pumpAndSettle();

    // The matching tile surfaces regardless of its section…
    expect(find.text('Backup & Restore'), findsOneWidget);
    // …and non-matching tiles/categories are filtered out.
    expect(find.text('Providers'), findsNothing);
    expect(find.text('Sources'), findsNothing);
  });
}
