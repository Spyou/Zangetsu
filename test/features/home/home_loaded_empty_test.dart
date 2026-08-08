// Task E2: Home's "provider returned no sections" branch (loadedEmpty in
// home_screen.dart's build) currently always renders _SourceUnavailable —
// worded as "source unavailable, try again" — even for a reading mode that
// simply has zero manga/novel sources installed. Nothing is "unavailable"
// there; there's nothing set up yet.
//
// HomeLoadedEmptyView is the decision extracted out of _HomeViewState.build
// into its own widget so it's testable without pumping the real HomeScreen
// (whose initState fires a real, un-DI'd network call — see
// test/features/home/reading_home_test.dart's file header for the same
// constraint hit by an earlier task).
//
// Anime mode never touches hasReadingSourcesFor's categorizedSources() call
// (ContentMode.isReading is false, short-circuited) — the anime-mode test
// below runs with ZERO source-related DI registered, which is itself part of
// the regression proof: the anime path cannot depend on installed sources.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:hive/hive.dart';
import 'dart:io';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/core/provider/cloudstream_provider.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/features/home/home_screen.dart';
import 'package:watch_app/features/sources/zangetsu_sources_screen.dart';

// Same seeding shape as test/features/sources/reading_source_buckets_test.dart
// — writes directly into the Hive boxes categorizedSources() reads, no
// network.

class _FakeManager implements ProviderRuntimeLoader {
  @override
  JsProvider? get(String id) => null;
  @override
  void load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) {}
  @override
  void setSettings(String sourceId, Map<String, dynamic> settings) {}
  @override
  void remove(String id) {}
}

class _FakeFetcher implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async =>
      CachedProvider(name: name, jsCode: '', url: url, fetchedAt: DateTime.now());
  @override
  Future<void> remove(String name) async {}
}

Future<void> _seedJsSource({
  required String id,
  required String type,
  String repoUrl = 'https://example.com/repo/index.json',
}) async {
  final reposBox = Hive.box<Map>(ProviderReposRegistry.boxName);
  final existingRaw = reposBox.get(repoUrl);
  final existingSources = existingRaw == null
      ? const <RepoSource>[]
      : ProviderRepo.fromJson(Map<String, dynamic>.from(existingRaw)).sources;
  final repo = ProviderRepo(
    url: repoUrl,
    name: 'Test Repo',
    description: '',
    lastSyncedAt: DateTime.now(),
    sources: [
      ...existingSources,
      RepoSource(id: id, name: id, version: '1.0.0', type: type, lang: 'en', file: '$id.js'),
    ],
  );
  await reposBox.put(repoUrl, repo.toJson());

  final regBox = Hive.box<Map>(ProviderRegistry.boxName);
  final entry = ProviderRegistryEntry(
    name: id,
    url: '$repoUrl/$id.js',
    originRepoUrl: repoUrl,
    displayName: id,
  );
  await regBox.put(ProviderRegistry.providerKey(repoUrl, id), entry.toJson());
}

Future<void> pumpEmptyView(
  WidgetTester tester, {
  required ContentMode mode,
  VoidCallback? onInstall,
  VoidCallback? onRetry,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HomeLoadedEmptyView(
          mode: mode,
          sourceName: 'allanime',
          onRetry: onRetry ?? () {},
          onInstallSources: onInstall ?? () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('HomeLoadedEmptyView — anime mode regression (no source DI needed)', () {
    testWidgets(
      'anime mode renders the existing "Couldn\'t load" wording with Retry, '
      'no install button',
      (tester) async {
        await pumpEmptyView(tester, mode: ContentMode.anime);

        expect(find.text("Couldn't load allanime"), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Browse repositories'),
            findsNothing);
        expect(find.textContaining('sources yet'), findsNothing);
      },
    );
  });

  group('HomeLoadedEmptyView — reading mode', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('home_loaded_empty_test');
      Hive.init(tempDir.path);
      await ProviderRegistry.init();
      await ProviderReposRegistry.init();
      await PlaybackPrefs.init();
      await CloudStreamManager.init();

      sl.registerSingleton<ProviderRegistry>(
        ProviderRegistry(
          downloader: _FakeFetcher(),
          manager: _FakeManager(),
          repos: ProviderReposRegistry(dio: Dio()),
        ),
      );
      sl.registerSingleton<ProviderReposRegistry>(ProviderReposRegistry(dio: Dio()));
      sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
      sl.registerSingleton<CloudStreamManager>(CloudStreamManager());
      sl.registerSingleton<AniyomiManager>(AniyomiManager());
      sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    });

    tearDown(() async {
      await sl.reset();
      await Hive.close();
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets(
      'manga mode, nothing installed: shows the install-CTA empty state, '
      'tapping the button fires onInstallSources',
      (tester) async {
        var installTapped = false;
        await pumpEmptyView(
          tester,
          mode: ContentMode.manga,
          onInstall: () => installTapped = true,
        );

        expect(find.text('No Manga sources yet'), findsOneWidget);
        final cta = find.widgetWithText(FilledButton, 'Browse repositories');
        expect(cta, findsOneWidget);
        expect(find.text("Couldn't load allanime"), findsNothing);

        await tester.tap(cta);
        expect(installTapped, isTrue);
      },
    );

    testWidgets(
      'manga mode, a manga source IS installed: falls back to the existing '
      '"source failed" wording, not the install CTA',
      (tester) async {
        await tester.runAsync(() => _seedJsSource(id: 'js:m', type: 'manga'));

        await pumpEmptyView(tester, mode: ContentMode.manga);

        expect(find.text("Couldn't load allanime"), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('No Manga sources yet'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Browse repositories'),
            findsNothing);
      },
    );

    testWidgets(
      'novel mode, nothing installed: shows the install-CTA empty state '
      'and opening it pushes ZangetsuSourcesScreen(openToRepos: true)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => HomeLoadedEmptyView(
                  mode: ContentMode.novel,
                  sourceName: 'allanime',
                  onRetry: () {},
                  onInstallSources: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const ZangetsuSourcesScreen(openToRepos: true),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('No Novel sources yet'), findsOneWidget);
        await tester.tap(
          find.widgetWithText(FilledButton, 'Browse repositories'),
        );
        await tester.pumpAndSettle();

        final screen = tester
            .widget<ZangetsuSourcesScreen>(find.byType(ZangetsuSourcesScreen));
        expect(screen.openToRepos, isTrue);
      },
    );
  });
}
