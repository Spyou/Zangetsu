import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';

/// A stand-in repo index URL — LNReader ships no built-in catalog, so
/// `fetchIndex` always takes a URL the caller supplies (a user-added repo in
/// the real app; just a literal here).
const _testIndexUrl = 'https://repo.test/plugins.min.json';

const _indexJson = '''
[
  {"id":"plugin-a","name":"Plugin A","site":"https://a.test/","lang":"en","version":"1.0.0","url":"https://cdn.test/a.js","iconUrl":"https://cdn.test/a.png"},
  {"id":"plugin-b","name":"Plugin B","site":"https://b.test/","lang":"en","version":"2.0.0","url":"https://cdn.test/b.js","iconUrl":"https://cdn.test/b.png"}
]
''';

/// `plugin-a`'s filter schema — non-empty, so `filtersFor()` tests have
/// something real to assert against (`plugin-b` stays `{}` for contrast).
const _sortFiltersJs = "{sort:{type:'Picker',label:'Sort'}}";

/// A minimal CommonJS fake plugin — same shape `test/core/lnreader/lnreader_provider_test.dart`
/// uses — exporting `default` with `name`/`site`/`filters` plus stub methods
/// so `pluginInfo()` and a real `loadPlugin()` round trip succeed.
String _pluginJs(String name, String site, {String filtersJs = '{}'}) => '''
module.exports.default = {
  name: '$name', site: '$site', version: '1.0.0', filters: $filtersJs,
  popularNovels: function (p, o) { return Promise.resolve([]); },
  searchNovels: function (t, p) { return Promise.resolve([]); },
  parseNovel: function (x) { return Promise.resolve({name: 'N', chapters: []}); },
  parseChapter: function (x) { return Promise.resolve(''); },
};
''';

const _metaA = LnReaderPluginMeta(
  id: 'plugin-a',
  name: 'Plugin A',
  site: 'https://a.test/',
  lang: 'en',
  version: '1.0.0',
  url: 'https://cdn.test/a.js',
  iconUrl: 'https://cdn.test/a.png',
);
const _metaB = LnReaderPluginMeta(
  id: 'plugin-b',
  name: 'Plugin B',
  site: 'https://b.test/',
  lang: 'en',
  version: '2.0.0',
  url: 'https://cdn.test/b.js',
  iconUrl: 'https://cdn.test/b.png',
);

/// A second, DIFFERENT install for `plugin-a`'s id — used by the uninstall
/// test to prove a reinstall doesn't serve stale cached/loaded state. Its
/// `popularNovels` returns a non-empty, identifiable result (unlike every
/// other fake plugin here, which returns `[]`) so a data call can tell the
/// two versions apart.
const _metaA2 = LnReaderPluginMeta(
  id: 'plugin-a',
  name: 'Plugin A v2',
  site: 'https://a2.test/',
  lang: 'en',
  version: '2.0.0',
  url: 'https://cdn.test/a2.js',
  iconUrl: 'https://cdn.test/a2.png',
);
const _pluginJsV2 = '''
module.exports.default = {
  name: 'Plugin A v2', site: 'https://a2.test/', version: '2.0.0', filters: {},
  popularNovels: function (p, o) { return Promise.resolve([{name: 'v2-novel', path: '/v2'}]); },
  searchNovels: function (t, p) { return Promise.resolve([]); },
  parseNovel: function (x) { return Promise.resolve({name: 'N', chapters: []}); },
  parseChapter: function (x) { return Promise.resolve(''); },
};
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late LnReaderExtensionService service;
  late LnReaderManager manager;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('lnreader_manager_test');
    Hive.init(tmpDir.path);
    service = LnReaderExtensionService(
      httpGet: (url) async {
        if (url == _testIndexUrl) return _indexJson;
        if (url == _metaA.url) {
          return _pluginJs('Plugin A', _metaA.site, filtersJs: _sortFiltersJs);
        }
        if (url == _metaB.url) return _pluginJs('Plugin B', _metaB.site);
        if (url == _metaA2.url) return _pluginJsV2;
        throw StateError('unexpected httpGet($url)');
      },
    );
    manager = LnReaderManager(
      service: service,
      fetch: (url, init) async => throw StateError(
        'fetch should not be called — the fake plugins never call fetchApi',
      ),
    );
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  test('fetchIndex() parses the 2-entry plugin index', () async {
    final metas = await service.fetchIndex(_testIndexUrl);

    expect(metas, hasLength(2));
    expect(metas[0].id, 'plugin-a');
    expect(metas[0].name, 'Plugin A');
    expect(metas[0].site, 'https://a.test/');
    expect(metas[0].lang, 'en');
    expect(metas[0].url, 'https://cdn.test/a.js');
    expect(metas[0].iconUrl, 'https://cdn.test/a.png');
    expect(metas[1].id, 'plugin-b');
    expect(metas[1].version, '2.0.0');
  });

  test('install() stores meta + js; installed()/jsFor() reflect it', () async {
    await manager.init(); // opens the box
    await service.install(_metaA);

    final list = service.installed();
    expect(list, hasLength(1));
    expect(list.single.id, 'plugin-a');
    expect(list.single.name, 'Plugin A');
    expect(list.single.version, '1.0.0');

    expect(
      service.jsFor('plugin-a'),
      _pluginJs('Plugin A', _metaA.site, filtersJs: _sortFiltersJs),
    );
    expect(service.jsFor('nope'), isNull);
  });

  test('init() opens the box but does NOT build the runtime', () async {
    await manager.init();
    expect(manager.runtimeBuilt, isFalse);
  });

  test(
    'installedSources lists every installed plugin as lnr:<id>/name pairs, without building the runtime',
    () async {
      await manager.init();
      await service.install(_metaA);
      await service.install(_metaB);

      expect(manager.runtimeBuilt, isFalse);
      final sources = manager.installedSources;
      expect(manager.runtimeBuilt, isFalse);

      expect(sources.map((s) => s.id).toSet(), {'lnr:plugin-a', 'lnr:plugin-b'});
      expect(sources.map((s) => s.name).toSet(), {'Plugin A', 'Plugin B'});
    },
  );

  test('metaFor() returns the stored meta, or null when not installed', () async {
    await manager.init();
    await service.install(_metaA);

    expect(manager.metaFor('plugin-a')?.name, 'Plugin A');
    expect(manager.metaFor('nope'), isNull);
  });

  test(
    'get() returns a provider built from stored meta alone, without building the runtime',
    () async {
      await manager.init();
      await service.install(_metaA);

      expect(manager.runtimeBuilt, isFalse);
      final provider = manager.get('lnr:plugin-a');
      expect(manager.runtimeBuilt, isFalse);

      expect(provider, isNotNull);
      expect(provider!.sourceId, 'lnr:plugin-a');
      expect(provider.displayName, 'Plugin A');

      // Cached: the same instance comes back on a second lookup.
      expect(manager.get('lnr:plugin-a'), same(provider));
    },
  );

  test('get() returns null for a plugin id that was never installed', () async {
    await manager.init();
    expect(manager.get('lnr:nope'), isNull);
  });

  test(
    'ensureLoaded() lazily builds the runtime once and tolerates a repeat call',
    () async {
      await manager.init();
      await service.install(_metaA);

      expect(manager.runtimeBuilt, isFalse);
      await manager.ensureLoaded('plugin-a');
      expect(manager.runtimeBuilt, isTrue);

      // Idempotent — a second call for the same plugin doesn't throw or
      // rebuild anything.
      await manager.ensureLoaded('plugin-a');
      expect(manager.runtimeBuilt, isTrue);
    },
  );

  test(
    'ensureLoaded() throws for a plugin id that was never installed, without building the runtime',
    () async {
      await manager.init();
      await expectLater(manager.ensureLoaded('nope'), throwsStateError);
      expect(manager.runtimeBuilt, isFalse);
    },
  );

  test('callPlugin() lazily loads the plugin, then invokes the method', () async {
    await manager.init();
    await service.install(_metaA);

    expect(manager.runtimeBuilt, isFalse);
    final result = await manager.callPlugin('plugin-a', 'popularNovels', [1, {}]);
    expect(manager.runtimeBuilt, isTrue);
    expect(result, isEmpty);
  });

  test("filtersFor() reads a loaded plugin's filter schema (empty when absent)", () async {
    await manager.init();
    await service.install(_metaA);
    await service.install(_metaB);

    await manager.ensureLoaded('plugin-a');
    await manager.ensureLoaded('plugin-b');

    expect(manager.filtersFor('plugin-a'), {
      'sort': {'type': 'Picker', 'label': 'Sort'},
    });
    expect(manager.filtersFor('plugin-b'), <String, dynamic>{});
  });

  test(
    'uninstall() clears storage, the provider cache, and loaded plugin state; '
    'reinstalling the same id with different js loads fresh (no stale short-circuit)',
    () async {
      await manager.init();
      await service.install(_metaA);

      final provider = manager.get('lnr:plugin-a'); // populates _providerCache
      expect(provider, isNotNull);
      final firstResult = await manager.callPlugin('plugin-a', 'popularNovels', [1, {}]); // loads it
      expect(manager.runtimeBuilt, isTrue);
      expect(firstResult, isEmpty);

      await manager.uninstall('plugin-a');

      expect(service.installed(), isEmpty);
      expect(manager.get('lnr:plugin-a'), isNull);

      // Reinstall the SAME id with DIFFERENT js, through the SAME manager/
      // runtime. If uninstall() left the old plugin id in the runtime's
      // loaded-id set, ensureLoaded() would short-circuit and skip loading
      // this new source entirely — and the stale JS would've already been
      // evicted from the runtime by uninstall(), so the call below would
      // throw "unknown plugin" instead of returning the v2 marker.
      await service.install(_metaA2);

      final provider2 = manager.get('lnr:plugin-a');
      expect(provider2, isNotNull);
      expect(provider2!.displayName, 'Plugin A v2');
      expect(provider2, isNot(same(provider))); // cache was actually rebuilt

      final secondResult = await manager.callPlugin('plugin-a', 'popularNovels', [1, {}]);
      expect(secondResult, [
        {'name': 'v2-novel', 'path': '/v2'},
      ]);
    },
  );
}
