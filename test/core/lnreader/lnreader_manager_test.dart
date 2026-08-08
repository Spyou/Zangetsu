import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';

const _indexJson = '''
[
  {"id":"plugin-a","name":"Plugin A","site":"https://a.test/","lang":"en","version":"1.0.0","url":"https://cdn.test/a.js","iconUrl":"https://cdn.test/a.png"},
  {"id":"plugin-b","name":"Plugin B","site":"https://b.test/","lang":"en","version":"2.0.0","url":"https://cdn.test/b.js","iconUrl":"https://cdn.test/b.png"}
]
''';

/// A minimal CommonJS fake plugin — same shape `test/core/lnreader/lnreader_provider_test.dart`
/// uses — exporting `default` with `name`/`site`/`filters` plus stub methods
/// so `pluginInfo()` and a real `loadPlugin()` round trip succeed.
String _pluginJs(String name, String site) => '''
module.exports.default = {
  name: '$name', site: '$site', version: '1.0.0', filters: {},
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
        if (url == LnReaderExtensionService.indexUrl) return _indexJson;
        if (url == _metaA.url) return _pluginJs('Plugin A', _metaA.site);
        if (url == _metaB.url) return _pluginJs('Plugin B', _metaB.site);
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
    final metas = await service.fetchIndex();

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

    expect(service.jsFor('plugin-a'), _pluginJs('Plugin A', _metaA.site));
    expect(service.jsFor('nope'), isNull);
  });

  test('init() opens the box but does NOT build the runtime', () async {
    await manager.init();
    expect(manager.runtimeBuilt, isFalse);
  });

  test(
    'reading .all lazily builds the runtime and returns one provider per '
    'installed plugin',
    () async {
      await manager.init();
      await service.install(_metaA);
      await service.install(_metaB);

      expect(manager.runtimeBuilt, isFalse);

      final providers = await manager.all;

      expect(manager.runtimeBuilt, isTrue);
      expect(providers, hasLength(2));
      expect(providers.map((p) => p.sourceId).toSet(), {
        'lnr:plugin-a',
        'lnr:plugin-b',
      });
      expect(providers.map((p) => p.displayName).toSet(), {
        'Plugin A',
        'Plugin B',
      });

      // Cached: reading again doesn't rebuild or reload.
      final again = await manager.all;
      expect(again, providers);
    },
  );
}
