import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';

/// On TV `loadAll` is skipped and providers load on demand, so opening a title
/// fires several calls that all want the same provider — the detail fetch, the
/// episode list and the playback prefetch. Each one would otherwise download it
/// again and evaluate it into the SHARED QuickJS runtime again.
void main() {
  late Directory dir;
  late _CountingFetcher fetcher;
  late _CountingLoader loader;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ensure-runtime');
    Hive.init(dir.path);
    await Hive.openBox<Map>(ProviderRegistry.boxName);
    await Hive.box<Map>(
      ProviderRegistry.boxName,
    ).put('repo::src', {
      'name': 'src',
      'url': 'https://repo.test/src.js',
      'enabled': true,
    });
    fetcher = _CountingFetcher();
    loader = _CountingLoader();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  ProviderRegistry registry() =>
      ProviderRegistry(downloader: fetcher, manager: loader);

  test('three overlapping calls load the source once', () async {
    final r = registry();

    await Future.wait([
      r.ensureRuntimeLoaded('src'),
      r.ensureRuntimeLoaded('src'),
      r.ensureRuntimeLoaded('src'),
    ]);

    expect(loader.loads, 1);
    expect(fetcher.fetches, 1);
  });

  test('every caller gets the same answer, not just the first', () async {
    final r = registry();

    final answers = await Future.wait([
      r.ensureRuntimeLoaded('src'),
      r.ensureRuntimeLoaded('src'),
    ]);

    expect(answers, everyElement(isFalse)); // this loader never registers it
  });

  test('a source with no registry entry never reaches the loader', () async {
    final r = registry();

    expect(await r.ensureRuntimeLoaded('missing'), isFalse);
    expect(loader.loads, 0);
  });

  test('the guard is released, so a later call can try again', () async {
    final r = registry();

    await r.ensureRuntimeLoaded('src');
    await r.ensureRuntimeLoaded('src');

    // Nothing here caches a FAILED load — the guard only collapses calls that
    // overlap, so a fresh attempt must still be allowed to run.
    expect(loader.loads, 2);
  });
}

class _CountingFetcher implements ProviderJsFetcher {
  int fetches = 0;

  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async {
    fetches++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return CachedProvider(
      name: name,
      jsCode: '',
      url: url,
      fetchedAt: DateTime.now(),
    );
  }

  @override
  Future<void> remove(String name) async {}
}

class _CountingLoader implements ProviderRuntimeLoader {
  int loads = 0;

  @override
  JsProvider? get(String id) => null;

  @override
  Future<void> load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) async {
    loads++;
  }

  @override
  void setSettings(String sourceId, Map<String, dynamic> settings) {}

  @override
  void remove(String id) {}
}
