import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/features/search/browse_sources_screen.dart';

import '../../support/picker_deps.dart';

/// Writes a repo manifest entry + an enabled registry entry directly into the
/// Hive boxes [ProviderRegistry]/[ProviderReposRegistry] read from — same
/// technique as `reading_source_buckets_test.dart`, the establshed way to put
/// a non-anime-typed row into `categorizedSources().movies` without the full
/// CloudStream plugin machinery.
Future<void> _seedJsSource({required String id, required String type}) async {
  const repoUrl = 'https://example.com/repo/index.json';
  final reposBox = Hive.box<Map>(ProviderReposRegistry.boxName);
  final repo = ProviderRepo(
    url: repoUrl,
    name: 'Test Repo',
    description: '',
    lastSyncedAt: DateTime.now(),
    sources: [RepoSource(id: id, name: id, version: '1.0.0', type: type, lang: 'en', file: '$id.js')],
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

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('browse_sources_screen');
    Hive.init(dir.path);
    await registerPickerDeps(
      aniyomi: [aniSource(id: 1, name: 'HiAnime')],
      mihon: [mihonSource(id: 1, name: 'MangaDex')],
    );
    await _seedJsSource(id: 'js:movie', type: 'movie');
  });

  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('Streaming tab combines the anime and movie buckets', (t) async {
    await t.pumpWidget(const MaterialApp(home: BrowseSourcesScreen()));
    await t.pumpAndSettle();

    // Streaming is the first (default) tab.
    expect(find.textContaining('HiAnime'), findsOneWidget);
    expect(find.textContaining('js:movie'), findsOneWidget);
    expect(find.textContaining('MangaDex'), findsNothing);
  });

  // The shell draws its floating dock OVER this tab, so the dock's height
  // arrives as a bottom inset on the screen's MediaQuery. It has to survive
  // the screen's own Scaffold + TabBarView and reach the list's padding —
  // testing the list widget alone would pass even if the inset never got
  // there, which is exactly how the last source ended up under the dock.
  testWidgets('the dock inset reaches the list through the screen', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: const EdgeInsets.only(bottom: 104)),
            child: const BrowseSourcesScreen(),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    final list = t.widget<ListView>(find.byType(ListView).first);
    expect(
      (list.padding! as EdgeInsets).bottom,
      greaterThanOrEqualTo(104.0),
      reason: 'the last source must scroll clear of the dock',
    );
  });

  testWidgets('Manga tab shows only the manga bucket', (t) async {
    await t.pumpWidget(const MaterialApp(home: BrowseSourcesScreen()));
    await t.pumpAndSettle();

    await t.tap(find.text('Manga'));
    await t.pumpAndSettle();

    expect(find.textContaining('MangaDex'), findsOneWidget);
    expect(find.textContaining('HiAnime'), findsNothing);
    expect(find.textContaining('js:movie'), findsNothing);
  });

  testWidgets('Novel tab says so when nothing is installed', (t) async {
    await t.pumpWidget(const MaterialApp(home: BrowseSourcesScreen()));
    await t.pumpAndSettle();

    await t.tap(find.text('Novel'));
    await t.pumpAndSettle();

    expect(find.text('No sources installed'), findsOneWidget);
  });

  // The all-sources content search action (SearchScreen(forceSources: true))
  // isn't exercised end to end here — pushing the real SearchScreen needs the
  // full search DI (CatalogueRepository/SearchHistory/etc.), which is already
  // covered by search_scope_screen_test.dart. This just proves the entry
  // point is present in the app bar.
  testWidgets('has a search action in the app bar', (t) async {
    await t.pumpWidget(const MaterialApp(home: BrowseSourcesScreen()));
    await t.pumpAndSettle();

    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
  });
}
