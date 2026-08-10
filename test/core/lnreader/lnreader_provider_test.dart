import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/lnreader/lnreader_extension_service.dart';
import 'package:watch_app/core/lnreader/lnreader_manager.dart';
import 'package:watch_app/core/lnreader/lnreader_provider.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';

const _fakePlugin = '''
module.exports.default = {
  name:'Fake', site:'https://fake.test/', version:'1.0.0', filters:{},
  popularNovels:function(p,o){return Promise.resolve([{name:'N1',path:'/n1',cover:'/c1.jpg'}]);},
  searchNovels:function(t,p){return Promise.resolve([{name:'S1',path:'/s1'}]);},
  parseNovel:function(x){return Promise.resolve({name:'N1',cover:'/c1.jpg',summary:'sum',author:'Auth',status:'Ongoing',genres:['Action'],chapters:[{name:'Ch1',path:'/n1/1'},{name:'Ch2',path:'/n1/2'}]});},
  parseChapter:function(x){return Promise.resolve('<p>chapter body</p>');}
};
''';

const _meta = LnReaderPluginMeta(
  id: 'fake',
  name: 'Fake',
  site: 'https://fake.test/',
  lang: 'en',
  version: '1.0.0',
  url: 'https://cdn.test/fake.js',
  iconUrl: 'https://cdn.test/fake.png',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late LnReaderExtensionService service;
  late LnReaderManager manager;
  late LnReaderProvider provider;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('lnreader_provider_test');
    Hive.init(tmpDir.path);
    service = LnReaderExtensionService(
      httpGet: (url) async {
        if (url == _meta.url) return _fakePlugin;
        throw StateError('unexpected httpGet($url)');
      },
    );
    manager = LnReaderManager(
      service: service,
      // Never called — every plugin method in _fakePlugin resolves without
      // touching fetchApi.
      fetch: (url, init) async => throw StateError('fetch should not be called'),
    );
    await manager.init();
    await service.install(_meta);

    // Same construction path SourceRepository will use: manager.get() —
    // built from stored meta alone, no runtime touched yet.
    provider = manager.get('lnr:fake')!;
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  test(
    'manager.get() constructs the provider from stored meta without building the runtime',
    () {
      expect(provider.sourceId, 'lnr:fake');
      expect(provider.displayName, 'Fake');
      expect(manager.runtimeBuilt, isFalse);
    },
  );

  test('getInfo() carries the novel type straight from meta, no runtime build', () async {
    final info = await provider.getInfo();
    expect(info.type, ProviderType.novel);
    expect(info.baseUrl, 'https://fake.test/');
    expect(info.name, 'Fake');
    expect(info.lang, 'en');
    expect(info.version, '1.0.0');
    expect(manager.runtimeBuilt, isFalse);
  });

  test('popular() lazily builds the runtime and maps popularNovels into MediaItems with resolved covers', () async {
    expect(manager.runtimeBuilt, isFalse);

    final items = await provider.popular();

    expect(manager.runtimeBuilt, isTrue);
    expect(items, hasLength(1));
    final item = items.first;
    expect(item.title, 'N1');
    expect(item.url, '/n1');
    expect(item.cover, 'https://fake.test/c1.jpg');
    expect(item.type, ProviderType.novel);
    expect(item.sourceId, 'lnr:fake');
  });

  test('search() lazily builds the runtime and maps searchNovels into MediaItems', () async {
    expect(manager.runtimeBuilt, isFalse);

    final items = await provider.search('term', 1);

    expect(manager.runtimeBuilt, isTrue);
    expect(items, hasLength(1));
    expect(items.first.title, 'S1');
    expect(items.first.url, '/s1');
  });

  test('getDetail() lazily builds the runtime and maps parseNovel into a MediaDetail with chapters', () async {
    expect(manager.runtimeBuilt, isFalse);

    final detail = await provider.getDetail('/n1');

    expect(manager.runtimeBuilt, isTrue);
    expect(detail.title, 'N1');
    expect(detail.description, 'sum');
    expect(detail.studios, ['Auth']);
    expect(detail.genres, ['Action']);
    expect(detail.status, MediaStatus.ongoing);
    expect(detail.cover, 'https://fake.test/c1.jpg');
    expect(detail.episodes, hasLength(2));
    expect(detail.episodes[0].title, 'Ch1');
    expect(detail.episodes[0].url, '/n1/1');
    expect(detail.episodes[1].title, 'Ch2');
    expect(detail.episodes[1].url, '/n1/2');
  });

  test('getEpisodes() returns the same chapters as getDetail', () async {
    final episodes = await provider.getEpisodes('/n1');
    expect(episodes, hasLength(2));
    expect(episodes[0].url, '/n1/1');
    expect(episodes[0].number, 1.0);
    expect(episodes[1].url, '/n1/2');
    expect(episodes[1].number, 2.0);
  });

  test('getText() lazily builds the runtime and maps parseChapter into ChapterText', () async {
    expect(manager.runtimeBuilt, isFalse);

    final text = await provider.getText('/n1/1');

    expect(manager.runtimeBuilt, isTrue);
    expect(text.html, '<p>chapter body</p>');
  });

  test('getHome() delegates to popular() and also builds the runtime', () async {
    expect(manager.runtimeBuilt, isFalse);

    final sections = await provider.getHome();

    expect(manager.runtimeBuilt, isTrue);
    expect(sections, hasLength(1));
    expect(sections!.first.title, 'Popular');
    expect(sections.first.items, hasLength(1));
    expect(sections.first.items.first.title, 'N1');
    // Paginable → carries a BrowseMore so "See all" can infinite-scroll.
    expect(sections.first.more?.kind, 'lnr_popular');
    expect(sections.first.more?.sourceId, provider.sourceId);
  });

  test('getVideoSources() is always empty and never touches the runtime', () async {
    expect(await provider.getVideoSources('/n1/1'), isEmpty);
    expect(manager.runtimeBuilt, isFalse);
  });

  test('getPages() throws — novels are text, not images — without touching the runtime', () {
    expect(() => provider.getPages('/n1/1'), throwsUnsupportedError);
    expect(manager.runtimeBuilt, isFalse);
  });
}
