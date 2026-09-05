// The genre list used to be hand-typed, which is how it ended up missing an
// entry AniList had always returned. It now comes from AniList and is cached,
// with the built-in list as the floor — these pin the rules that make that
// swap safe: never show an empty grid, never lose the list to a bad fetch,
// and never let a fetched list smuggle the adult genre past Privacy.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/genre_catalog.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('genre_catalog');
    Hive.init(dir.path);
    await GenreCatalog.init();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('falls back to the built-in list before anything is fetched', () {
    expect(GenreCatalog.cached, isEmpty);
    expect(
      GenreCatalog.genresFor(ZKind.anime),
      metaGenresFor(ZKind.anime),
    );
  });

  test('prefers the fetched list once it exists', () async {
    await GenreCatalog.save(['Action', 'Isekai', 'Comedy']);
    // 'Isekai' is not in the built-in list; seeing it proves the swap.
    expect(GenreCatalog.genresFor(ZKind.anime), ['Action', 'Comedy', 'Isekai']);
  });

  test('an empty answer does not wipe a good list', () async {
    await GenreCatalog.save(['Action', 'Comedy']);
    await GenreCatalog.save(const []);
    expect(GenreCatalog.cached, ['Action', 'Comedy']);
  });

  test('a fetched list still obeys the Privacy switch', () async {
    // AniList's real GenreCollection contains it outright.
    await GenreCatalog.save(['Action', kAdultGenre, 'Comedy']);
    expect(GenreCatalog.genresFor(ZKind.anime), isNot(contains(kAdultGenre)));
    expect(
      GenreCatalog.genresFor(ZKind.anime, adult: true),
      contains(kAdultGenre),
    );
  });

  test('movie/TV ignore the AniList list entirely', () async {
    // TMDB genres are a different vocabulary with their own ids.
    await GenreCatalog.save(['Isekai', 'Mecha']);
    expect(GenreCatalog.genresFor(ZKind.movie), metaGenresFor(ZKind.movie));
    expect(GenreCatalog.genresFor(ZKind.tv), metaGenresFor(ZKind.tv));
  });

  test('a saved list is stale-checked, and a fresh one is not', () async {
    expect(GenreCatalog.isStale, isTrue, reason: 'nothing fetched yet');
    await GenreCatalog.save(['Action']);
    expect(GenreCatalog.isStale, isFalse);
  });

  test('the fetched list is sorted, whatever order it arrived in', () async {
    await GenreCatalog.save(['Zombie', 'Action', 'Mecha']);
    expect(GenreCatalog.genresFor(ZKind.anime), ['Action', 'Mecha', 'Zombie']);
  });
}
