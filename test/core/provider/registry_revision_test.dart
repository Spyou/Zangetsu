import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';

/// [ProviderRegistry.revision] is what lets SourceRepository cache
/// `pickableSources` — a getter that reads and JSON-parses every registry
/// entry, and that the source matcher calls once per candidate lookup. A home
/// reload ran it twelve times inside one 30ms frame with 214 sources
/// installed, on the UI thread, which is what froze the app after tapping
/// "Solve Cloudflare".
///
/// The revision is driven by Hive's own change stream rather than by a counter
/// bumped in each mutating method, because a MISSED bump leaves a source
/// invisible until restart — worse than the slowness being fixed. These pin
/// that it really does move on every kind of write.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('registry-rev');
    Hive.init(dir.path);
    await Hive.openBox<Map>(ProviderRegistry.boxName);
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Box<Map> box() => Hive.box<Map>(ProviderRegistry.boxName);

  ProviderRegistry registry() => ProviderRegistry(
    downloader: _NoopFetcher(),
    manager: _NoopLoader(),
  );

  test('starts at zero and is stable while nothing is written', () async {
    final r = registry();
    expect(r.revision, 0);
    expect(r.revision, 0, reason: 'reading it must not move it');
  });

  test('moves when an entry is added', () async {
    final r = registry();
    r.revision; // arms the watch
    await box().put('repo::src', {'name': 'src', 'enabled': true});
    await Future<void>.delayed(Duration.zero); // let the stream deliver
    expect(r.revision, greaterThan(0));
  });

  test('moves when an entry is CHANGED, not just added or removed', () async {
    // The case a key count would miss: enabling or disabling a source rewrites
    // a value and leaves the key set identical. Miss it and that source stays
    // hidden (or stays visible) until the app restarts.
    final r = registry();
    await box().put('repo::src', {'name': 'src', 'enabled': true});
    r.revision;
    await Future<void>.delayed(Duration.zero);
    final before = r.revision;

    await box().put('repo::src', {'name': 'src', 'enabled': false});
    await Future<void>.delayed(Duration.zero);
    expect(r.revision, greaterThan(before));
  });

  test('moves when an entry is deleted', () async {
    final r = registry();
    await box().put('repo::src', {'name': 'src', 'enabled': true});
    r.revision;
    await Future<void>.delayed(Duration.zero);
    final before = r.revision;

    await box().delete('repo::src');
    await Future<void>.delayed(Duration.zero);
    expect(r.revision, greaterThan(before));
  });
}

class _NoopFetcher implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async => CachedProvider(
    name: name,
    jsCode: '',
    url: url,
    fetchedAt: DateTime.now(),
  );
  @override
  Future<void> remove(String name) async {}
}

class _NoopLoader implements ProviderRuntimeLoader {
  @override
  JsProvider? get(String id) => null;
  @override
  Future<void> load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) async {}
  @override
  void setSettings(String sourceId, Map<String, dynamic> settings) {}
  @override
  void remove(String id) {}
}
