import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';
import 'package:watch_app/core/provider/provider_repo_registry.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/features/sources/zangetsu_sources_screen.dart';

// ── Fakes (mirrors test/provider/provider_registry_test.dart) ────────────────

/// No-op runtime loader — this screen never installs anything in these tests.
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
  void setSettings(String sourceId, Map<String, dynamic> s) {}

  @override
  void remove(String id) {}
}

/// Stub fetcher — repo providers aren't exercised in these tests.
class _FakeFetcher implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async => CachedProvider(
    name: name,
    jsCode: '// $name',
    url: url,
    fetchedAt: DateTime.now(),
  );

  @override
  Future<void> remove(String name) async {}
}

void main() {
  late Directory tempDir;

  setUp(() async {
    // Real Hive (temp dir) + real registries — SourcesBloc subscribes to
    // both boxes' `.watch()` in its constructor, so a plain mock can't
    // stand in without reimplementing that surface.
    tempDir = await Directory.systemTemp.createTemp('zangetsu_sources_test');
    Hive.init(tempDir.path);
    await ProviderRegistry.init();
    await ProviderReposRegistry.init();

    final sl = GetIt.instance;
    sl.registerSingleton<AppMode>(const AppMode(isTv: true));
    sl.registerSingleton<ProviderRegistry>(
      ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
    );
    sl.registerSingleton<ProviderReposRegistry>(
      ProviderReposRegistry(dio: Dio()),
    );
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    await tempDir.delete(recursive: true);
  });

  testWidgets(
    'ZangetsuSourcesScreen (TV) exposes semantics labels for its tab chips, '
    'Back button and Add-repo action — with no duplicate-text nodes',
    (tester) async {
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(const MaterialApp(home: ZangetsuSourcesScreen()));
      await tester.pumpAndSettle();

      // Installed tab chip: autofocused, so this is where the D-pad lands.
      expect(
        tester.getSemantics(find.bySemanticsLabel('Installed')),
        matchesSemantics(
          label: 'Installed',
          isButton: true,
          isFocusable: true,
          isFocused: true,
          hasTapAction: true,
          // Framework-supplied for anything focusable; matchesSemantics fails
          // on any action it wasn't told to expect.
          hasFocusAction: true,
        ),
      );
      // Each of these is a single announced node — no leftover sibling
      // Text nodes duplicating the same label.
      for (final label in ['Repositories', 'Back']) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }

      // Switch to Repositories: with no repos added, the "Add repo" row
      // becomes reachable and announces its own label once. TvFocusable has
      // no gesture recognizer (D-pad OK / TalkBack double-tap are its only
      // real inputs), so invoke its onTap directly rather than tester.tap.
      final repositoriesChip = tester
          .widgetList<TvFocusable>(find.byType(TvFocusable))
          .firstWhere((f) => f.semanticLabel == 'Repositories');
      repositoriesChip.onTap();
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Add repo'), findsOneWidget);

      handle.dispose();
    },
  );
}
