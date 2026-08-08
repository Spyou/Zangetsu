import 'package:flutter_test/flutter_test.dart';

import 'package:watch_app/core/lnreader/lnreader_provider.dart';
import 'package:watch_app/core/lnreader/lnreader_runtime.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LnReaderRuntime runtime;
  late LnReaderProvider provider;

  setUp(() async {
    runtime = LnReaderRuntime(
      // Never called — every plugin method in _fakePlugin resolves without
      // touching fetchApi.
      fetch: (url, init) async => throw StateError('fetch should not be called'),
    );
    await runtime.loadPlugin('fake', _fakePlugin);
    provider = LnReaderProvider(
      runtime: runtime,
      pluginId: 'fake',
      info: const {'name': 'Fake', 'site': 'https://fake.test/', 'filters': {}},
    );
  });

  tearDown(() => runtime.dispose());

  test('sourceId is lnr-prefixed and getInfo carries the novel type', () async {
    expect(provider.sourceId, 'lnr:fake');
    expect(provider.displayName, 'Fake');
    final info = await provider.getInfo();
    expect(info.type, ProviderType.novel);
    expect(info.baseUrl, 'https://fake.test/');
  });

  test('popular() maps popularNovels into MediaItems with resolved covers', () async {
    final items = await provider.popular();
    expect(items, hasLength(1));
    final item = items.first;
    expect(item.title, 'N1');
    expect(item.url, '/n1');
    expect(item.cover, 'https://fake.test/c1.jpg');
    expect(item.type, ProviderType.novel);
    expect(item.sourceId, 'lnr:fake');
  });

  test('search() maps searchNovels into MediaItems', () async {
    final items = await provider.search('term', 1);
    expect(items, hasLength(1));
    expect(items.first.title, 'S1');
    expect(items.first.url, '/s1');
  });

  test('getDetail() maps parseNovel into a MediaDetail with chapters', () async {
    final detail = await provider.getDetail('/n1');
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

  test('getText() maps parseChapter into ChapterText', () async {
    final text = await provider.getText('/n1/1');
    expect(text.html, '<p>chapter body</p>');
  });

  test('getVideoSources() is always empty', () async {
    expect(await provider.getVideoSources('/n1/1'), isEmpty);
  });

  test('getPages() throws — novels are text, not images', () {
    expect(() => provider.getPages('/n1/1'), throwsUnsupportedError);
  });
}
