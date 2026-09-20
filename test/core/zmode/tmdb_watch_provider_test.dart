import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/ui/streaming_prefs.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';

Map<String, dynamic> _page(List<(int, String)> rows) => {
  'results': [
    for (final (id, title) in rows)
      {'id': id, 'name': title, 'title': title, 'poster_path': '/p.png'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late List<(String, Map<String, dynamic>)> calls;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tmdb_wp');
    Hive.init(dir.path);
    await StreamingPrefs.init();
    StreamingPrefs.deviceRegion = () => 'IN';
    calls = [];
  });

  tearDown(() async {
    StreamingPrefs.resetDeviceRegionForTest();
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  TmdbCatalogue build(Map<String, Map<String, dynamic>> byPath) =>
      TmdbCatalogue((path, params) async {
        calls.add((path, params));
        return byPath[path];
      });

  test('a wp: row queries both discover endpoints with the provider and region',
      () async {
    final c = build({
      '/discover/tv': _page([(1, 'Show')]),
      '/discover/movie': _page([(2, 'Film')]),
    });

    await c.browseRow(TmdbCatalogue.wpRowId(8), 2);

    expect(calls.map((c) => c.$1).toSet(), {'/discover/tv', '/discover/movie'});
    for (final (_, params) in calls) {
      expect(params['with_watch_providers'], '8');
      expect(params['watch_region'], 'IN');
      expect(params['page'], 2);
    }
  });

  test('the region is read per call, not frozen at construction', () async {
    final c = build({
      '/discover/tv': _page([(1, 'Show')]),
      '/discover/movie': _page([(2, 'Film')]),
    });
    await c.browseRow(TmdbCatalogue.wpRowId(8), 1);
    await StreamingPrefs.setRegion('GB');
    calls.clear();
    await c.browseRow(TmdbCatalogue.wpRowId(8), 1);
    for (final (_, params) in calls) {
      expect(params['watch_region'], 'GB');
    }
  });

  test('series and films are interleaved, not one then the other', () async {
    final c = build({
      '/discover/tv': _page([(1, 'S1'), (3, 'S2'), (5, 'S3')]),
      '/discover/movie': _page([(2, 'M1'), (4, 'M2')]),
    });

    final items = await c.browseRow(TmdbCatalogue.wpRowId(8), 1);

    expect(items.map((i) => i.title).toList(), ['S1', 'M1', 'S2', 'M2', 'S3']);
  });

  test('one endpoint failing still returns the other', () async {
    final c = build({
      '/discover/tv': _page([(1, 'S1')]),
    });
    final items = await c.browseRow(TmdbCatalogue.wpRowId(8), 1);
    expect(items.map((i) => i.title).toList(), ['S1']);
  });

  test('a series from a wp: row is typed as a series, a film as a film',
      () async {
    final c = build({
      '/discover/tv': _page([(1, 'S1')]),
      '/discover/movie': _page([(2, 'M1')]),
    });
    final items = await c.browseRow(TmdbCatalogue.wpRowId(8), 1);
    expect(items.firstWhere((i) => i.title == 'S1').tmdbIsTv, isTrue);
    expect(items.firstWhere((i) => i.title == 'M1').tmdbIsTv, isFalse);
  });

  test('a malformed wp: id is an empty list, not a crash', () async {
    final c = build({});
    expect(await c.browseRow('wp:', 1), isEmpty);
    expect(await c.browseRow('wp:abc', 1), isEmpty);
    expect(calls, isEmpty, reason: 'nothing to ask for, so do not ask');
  });

  test('the existing path endpoints are untouched', () async {
    final c = build({
      '/movie/popular': _page([(9, 'Pop')]),
    });
    final items = await c.browseRow('/movie/popular', 3);
    expect(items.single.title, 'Pop');
    expect(calls.single.$1, '/movie/popular');
    expect(calls.single.$2['page'], 3);
  });
}
