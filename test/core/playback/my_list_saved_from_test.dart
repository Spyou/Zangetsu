// A saved title keeps the catalogue it came from. It cannot be worked out
// afterwards — AniList and MAL both key on `mal:`, TMDB and Simkl both on
// `tmdb:` — so it is recorded once, on the way into the list.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

MediaItem _item({String? savedFrom, String sourceId = ZmodeIds.sourceId}) =>
    MediaItem(
      id: 'mal:1735',
      title: 'Naruto',
      url: 'zm://anime/mal:1735',
      type: ProviderType.anime,
      sourceId: sourceId,
      savedFrom: savedFrom,
    );

void main() {
  test('the origin survives a save and reload', () {
    final back = MediaItem.fromJson(_item(savedFrom: 'AniList').toJson());
    expect(back.savedFrom, 'AniList');
  });

  test('an entry saved before this existed reads as null', () {
    // Old rows have no such key; they must load, not throw.
    final json = _item().toJson()..remove('savedFrom');
    expect(MediaItem.fromJson(json).savedFrom, isNull);
  });

  test('copyWith can stamp it without disturbing anything else', () {
    final stamped = _item().copyWith(savedFrom: 'Simkl');
    expect(stamped.savedFrom, 'Simkl');
    expect(stamped.id, 'mal:1735');
    expect(stamped.url, 'zm://anime/mal:1735');
  });

  test('two entries differing only in origin are not equal', () {
    // They are different rows: the same title saved from AniList and from MAL
    // should not silently collapse into one.
    expect(_item(savedFrom: 'AniList'), isNot(_item(savedFrom: 'MyAnimeList')));
  });

  test('a source title carries its source, not a catalogue', () {
    // Nothing to stamp: sourceId already names where it came from.
    final src = _item(sourceId: 'ani:1');
    expect(src.savedFrom, isNull);
    expect(src.sourceId, 'ani:1');
  });
}
