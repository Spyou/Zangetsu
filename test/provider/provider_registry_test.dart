import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/provider/provider_downloader.dart';
import 'package:watch_app/core/provider/provider_manager.dart';
import 'package:watch_app/core/provider/provider_registry.dart';

/// No-op runtime loader: records loaded/removed ids without touching the
/// native QuickJS runtime (which can't spin up in a plain Dart test).
class _FakeManager implements ProviderRuntimeLoader {
  final Set<String> loaded = {};
  final List<MapEntry<String, Map<String, dynamic>>> settings = [];

  @override
  JsProvider? get(String id) => null;

  @override
  void load({
    required String sourceId,
    required String jsSource,
    String originRepoUrl = '',
    String displayName = '',
  }) {
    loaded.add(sourceId);
  }

  @override
  void setSettings(String sourceId, Map<String, dynamic> s) =>
      settings.add(MapEntry(sourceId, s));

  @override
  void remove(String id) => loaded.remove(id);
}

/// Stub fetcher — repo providers aren't exercised in these tests.
class _FakeFetcher implements ProviderJsFetcher {
  @override
  Future<CachedProvider> fetch({
    required String name,
    required String url,
    bool force = false,
  }) async =>
      CachedProvider(
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
  late _FakeManager manager;
  late ProviderRegistry registry;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('prov_reg_test');
    Hive.init(tempDir.path);
    await ProviderRegistry.init();
    manager = _FakeManager();
    registry = ProviderRegistry(
      downloader: _FakeFetcher(),
      manager: manager,
    );
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await tempDir.delete(recursive: true);
  });

  test('key helpers round-trip a composite key', () {
    final key = ProviderRegistry.providerKey(kBundledRepoUrl, 'allanime');
    expect(key, 'bundled://::allanime');
    expect(ProviderRegistry.sourceIdOf(key), 'allanime');
    expect(ProviderRegistry.repoUrlOf(key), kBundledRepoUrl);
  });

  test('installFromBundled persists an enabled entry and loads it', () async {
    await registry.installFromBundled(
      name: 'allanime',
      jsSource: '// allanime js',
      displayName: 'AllAnime',
    );

    final all = registry.getAll();
    expect(all.length, 1);

    final entry = all.single;
    expect(entry.name, 'allanime');
    expect(entry.enabled, isTrue);
    expect(entry.originRepoUrl, kBundledRepoUrl);
    expect(entry.displayName, 'AllAnime');
    expect(entry.isBundled, isTrue);

    // It was pushed into the (fake) runtime.
    expect(manager.loaded, contains('allanime'));

    // Composite key parses back to the right pieces.
    final key = ProviderRegistry.providerKey(kBundledRepoUrl, 'allanime');
    expect(ProviderRegistry.sourceIdOf(key), 'allanime');
    expect(ProviderRegistry.repoUrlOf(key), kBundledRepoUrl);
    expect(registry.entryFor('allanime')?.name, 'allanime');
  });

  test('setEnabled(false) flips the flag and drops it from the runtime',
      () async {
    await registry.installFromBundled(
      name: 'allanime',
      jsSource: '// allanime js',
    );
    final key = ProviderRegistry.providerKey(kBundledRepoUrl, 'allanime');

    await registry.setEnabled(key, false);
    expect(registry.getAll().single.enabled, isFalse);
    expect(manager.loaded, isNot(contains('allanime')));

    // Re-enabling reloads it from the cached bundled JS.
    await registry.setEnabled(key, true);
    expect(registry.getAll().single.enabled, isTrue);
    expect(manager.loaded, contains('allanime'));
  });

  test('loadAll reloads enabled bundled entries from the cached JS',
      () async {
    await registry.installFromBundled(name: 'allanime', jsSource: '// a');
    await registry.installFromBundled(name: 'netmirror_nf', jsSource: '// nm');
    manager.loaded.clear();

    final loaded = await registry.loadAll();
    expect(loaded.length, 2);
    expect(manager.loaded, containsAll(['allanime', 'netmirror_nf']));
  });
}
