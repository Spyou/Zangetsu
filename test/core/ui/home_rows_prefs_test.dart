import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/ui/home_rows_prefs.dart';

// Dumb storage still has invariants worth pinning: a layout that was never
// customized must read as null (so the caller falls back to the default
// arrangement), saves must round-trip verbatim — including the hidden-row
// prefix, which this class must not interpret — and every mutation must bump
// the revision main.dart listens to.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('home_rows_prefs_test');
    Hive.init(dir.path);
    await HomeRowsPrefs.init();
  });

  tearDown(() async {
    HomeRowsPrefs.revision.value = 0;
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a layout with nothing saved reads as null', () {
    expect(HomeRowsPrefs.savedFor('anilist::anime'), isNull);
  });

  test('save round-trips the entries verbatim, prefixes included', () async {
    await HomeRowsPrefs.save('anilist::anime', [
      'local:continue',
      '!tracker:continue',
      'section:Trending',
    ]);
    expect(HomeRowsPrefs.savedFor('anilist::anime'), [
      'local:continue',
      '!tracker:continue',
      'section:Trending',
    ]);
  });

  test('each layout key is independent', () async {
    await HomeRowsPrefs.save('anilist::anime', ['local:continue']);
    await HomeRowsPrefs.save('tmdb::video', ['section:Trending']);
    expect(HomeRowsPrefs.savedFor('anilist::anime'), ['local:continue']);
    expect(HomeRowsPrefs.savedFor('tmdb::video'), ['section:Trending']);
  });

  test('save and reset bump the revision', () async {
    var rev = HomeRowsPrefs.revision.value;
    await HomeRowsPrefs.save('anilist::anime', ['local:continue']);
    expect(HomeRowsPrefs.revision.value, rev + 1);
    rev = HomeRowsPrefs.revision.value;
    await HomeRowsPrefs.resetFor('anilist::anime');
    expect(HomeRowsPrefs.revision.value, rev + 1);
    expect(HomeRowsPrefs.savedFor('anilist::anime'), isNull);
  });
}
