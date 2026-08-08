import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:watch_app/features/sources/zangetsu_recommended_repos.dart';
import 'package:watch_app/features/sources/zangetsu_sources_screen.dart';

// The Zangetsu (JS-provider) "Add repo" dialog used to offer the Sozo Read
// pack as a recommended suggestion. That pack was dropped along with the
// Zangetsu reading-source entry points — those JS sources are search-only
// (no popular/latest), so selecting one left Home with nothing to render.
// Manga is served by Mihon extensions instead; novel support is planned as
// its own extension path. kRecommendedZangetsuRepos is now empty by design,
// and the dialog's RECOMMENDED section is gated on it being non-empty — this
// checks the dialog still renders cleanly with no stray section left behind.
// PHONE view only (isTv: false); the TV variant (_ZTvAddRepoDialog /
// _ZTvView) is untouched and not exercised here.

/// No-op runtime loader — no source is actually installed in these tests.
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

/// Stub fetcher — installing sources isn't exercised in these tests.
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

/// Fake HTTP transport for [ProviderReposRegistry.fetchAndCache] — returns a
/// canned manifest for ANY request so adding the recommended repo never
/// touches the network.
class _FakeManifestAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = jsonEncode({
      'name': "Spyou's Sozo Providers",
      'description': 'Default manga + novel sources for Sozo Read.',
      'sources': [
        {
          'id': 'mangapill',
          'name': 'Mangapill',
          'version': '1.0.0',
          'type': 'manga',
          'lang': 'en',
          'file': 'mangapill.js',
        },
      ],
    });
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('zangetsu_add_repo_test');
    Hive.init(tempDir.path);
    await ProviderRegistry.init();
    await ProviderReposRegistry.init();

    final sl = GetIt.instance;
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
    sl.registerSingleton<ProviderRegistry>(
      ProviderRegistry(downloader: _FakeFetcher(), manager: _FakeManager()),
    );
    sl.registerSingleton<ProviderReposRegistry>(
      ProviderReposRegistry(
        dio: Dio()..httpClientAdapter = _FakeManifestAdapter(),
      ),
    );
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    await tempDir.delete(recursive: true);
  });

  // Fixed pumps rather than pumpAndSettle(): the dialog's manifest-URL
  // TextField is autofocus:true, and its blinking cursor keeps scheduling
  // frames for as long as it's focused — pumpAndSettle() would wait for
  // that to stop, which it never does, and hang until its own internal
  // timeout. A couple of pumps is plenty for the AlertDialog's enter
  // transition.
  Future<void> openAddRepoDialog(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: ZangetsuSourcesScreen()));
    await tester.pump();
    await tester.tap(find.text('Add Zangetsu repo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'kRecommendedZangetsuRepos is empty, and the add-repo dialog renders '
    'with no stray RECOMMENDED section',
    (tester) async {
      expect(kRecommendedZangetsuRepos, isEmpty);

      await openAddRepoDialog(tester);

      expect(find.text('Add repo'), findsOneWidget);
      expect(find.text('RECOMMENDED'), findsNothing);
      // The dialog's own two fields (name + manifest URL) still render
      // normally — an empty suggestion list doesn't take the rest of the
      // dialog down with it. Scoped to the AlertDialog itself since the
      // screen underneath has its own search TextField in the tree too.
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        findsNWidgets(2),
      );
    },
  );
}
