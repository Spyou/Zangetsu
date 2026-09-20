import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/metadata/streaming_service.dart';
import 'package:watch_app/core/ui/streaming_prefs.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';

Map<String, dynamic> _page(String title) => {
  'results': [
    {'id': 1, 'name': title, 'title': title, 'poster_path': '/p.png'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tmdb_rows');
    Hive.init(dir.path);
    await StreamingPrefs.init();
    StreamingPrefs.deviceRegion = () => 'IN';
  });

  tearDown(() async {
    StreamingPrefs.resetDeviceRegionForTest();
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('with nothing pinned, the row titles are exactly what they were', () {
    final titles = TmdbCatalogue.rowTitles();
    expect(titles, contains('Trending'));
    expect(titles, contains('Popular movies'));
    expect(titles.length, 7, reason: 'the seven shipped rows, unchanged');
  });

  test('a pinned service appears in the row titles, after the fixed rows',
      () async {
    await StreamingPrefs.setPinned(const [
      StreamingPin(id: 8, name: 'Netflix'),
    ]);
    final titles = TmdbCatalogue.rowTitles();
    expect(titles.length, 8);
    expect(titles.last, 'Netflix');
  });

  test('home() emits a paginable row per pin, keyed by provider id', () async {
    await StreamingPrefs.setPinned(const [
      StreamingPin(id: 8, name: 'Netflix'),
    ]);
    final c = TmdbCatalogue((path, params) async => _page('Thing'));

    final sections = await c.home();
    final netflix = sections.where((s) => s.title == 'Netflix').toList();

    expect(netflix, hasLength(1));
    expect(netflix.single.more, isNotNull);
    expect(netflix.single.more!.kind, 'zm_video');
    expect(netflix.single.more!.categoryId, 'wp:8');
    expect(netflix.single.items, isNotEmpty);
  });

  test('a pinned service with nothing to show is dropped, not left blank',
      () async {
    await StreamingPrefs.setPinned(const [
      StreamingPin(id: 8, name: 'Netflix'),
    ]);
    final c = TmdbCatalogue(
      (path, params) async =>
          path.startsWith('/discover') ? {'results': <dynamic>[]} : _page('X'),
    );

    final sections = await c.home();
    expect(sections.where((s) => s.title == 'Netflix'), isEmpty);
    expect(sections, isNotEmpty, reason: 'the fixed rows still came back');
  });

  test('service rows come after the shipped rows', () async {
    await StreamingPrefs.setPinned(const [
      StreamingPin(id: 8, name: 'Netflix'),
    ]);
    final c = TmdbCatalogue((path, params) async => _page('Thing'));
    final titles = (await c.home()).map((s) => s.title).toList();
    expect(titles.last, 'Netflix');
    expect(titles.first, 'Now playing');
  });

  test('the row id the editor stores matches the section home() emits',
      () async {
    // The Home-rows editor keys a row by `section:<title>`, so the title in
    // rowTitles() and the title on the HomeSection have to be the same string
    // or a pinned row can never be reordered or hidden.
    await StreamingPrefs.setPinned(const [
      StreamingPin(id: 283, name: 'Crunchyroll'),
    ]);
    final c = TmdbCatalogue((path, params) async => _page('Thing'));
    final sections = await c.home();
    expect(
      TmdbCatalogue.rowTitles().last,
      sections.last.title,
    );
  });
}
