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
import 'package:watch_app/core/playback/search_prefs.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/state/active_source_cubit.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';
import 'package:watch_app/features/auth/auth_cubit.dart';
import 'package:watch_app/features/settings/settings_screen.dart';

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
    final sl = GetIt.instance;
    sl
      ..registerSingleton<AppMode>(AppMode(isTv: false))
      ..registerSingleton<SearchPrefs>(_StubSearchPrefs())
      ..registerSingleton<ProviderRegistry>(_StubProviderRegistry())
      ..registerSingleton<AniListService>(_StubAniList())
      ..registerSingleton<MalService>(_StubMal())
      ..registerSingleton<SimklService>(_StubSimkl())
      ..registerSingleton<DownloadPrefs>(DownloadPrefs());
    activeCubit = ActiveSourceCubit();
  });

  tearDown(() async {
    await activeCubit.close();
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (_hiveDir.existsSync()) await _hiveDir.delete(recursive: true);
  });

  testWidgets('Settings renders labeled sections with every tile grouped',
      (tester) async {
    _mockPathProvider(tester);
    // Tall surface so the lazy ListView builds every section.
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final authCubit = AuthCubit(AppwriteService());
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
    await tester.pump();

    // The new section labels (SettingsSectionLabel renders them uppercase).
    for (final label in [
      'ACCOUNT & SYNC',
      'SOURCES',
      'PLAYBACK & DOWNLOADS',
      'MORE',
    ]) {
      expect(find.text(label), findsOneWidget, reason: 'label: $label');
    }
    // The Notifications section is Android-only — absent on the test host.
    expect(find.text('NOTIFICATIONS'), findsNothing);
    expect(find.text('Notifications'), findsNothing);

    // Every cross-platform tile still renders exactly once.
    for (final t in [
      'Watch Party',
      'Backup & Restore',
      'Connections',
      'Discord',
      'Providers',
      'Active source',
      'Source health',
      'Playback',
      'Storage',
      'Download location',
      'Search layout',
      'How it works',
      'Privacy',
      'Check for updates',
      'Support the app',
      'Developers',
      'About',
    ]) {
      expect(find.text(t), findsOneWidget, reason: 'tile: $t');
    }
  });
}
