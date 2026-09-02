// Tapping a tracker entry used to drop you into a search for its own title.
// The stub carries the id the metadata catalogue is keyed by, so the title can
// be opened directly — search is only for an entry with nothing to go on.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

/// Mirrors `_canonicalOf` — the mapping is the part worth pinning, and it is
/// pure.
ZCanonical? canonicalOf(MediaItem stub) {
  final mal = stub.malId;
  if (mal != null) {
    return ZCanonical(
      switch (stub.type) {
        ProviderType.manga => ZKind.manga,
        ProviderType.novel => ZKind.novel,
        _ => ZKind.anime,
      },
      'mal:$mal',
    );
  }
  final tmdb = stub.tmdbId;
  if (tmdb != null) {
    return ZCanonical(stub.tmdbIsTv ? ZKind.tv : ZKind.movie, 'tmdb:$tmdb');
  }
  return null;
}

MediaItem _stub({
  int? malId,
  int? tmdbId,
  bool tmdbIsTv = false,
  ProviderType type = ProviderType.anime,
}) => MediaItem(
  id: 'tracker:x',
  title: 'Some Title',
  url: '', // tracker stubs carry no provider url
  type: type,
  sourceId: '',
  malId: malId,
  tmdbId: tmdbId,
  tmdbIsTv: tmdbIsTv,
);

void main() {
  test('an AniList/MAL entry opens as its anime title', () {
    final c = canonicalOf(_stub(malId: 1735))!;
    expect(c.kind, ZKind.anime);
    expect(ZmodeIds.showUrl(c), 'zm://anime/mal:1735');
  });

  test('a manga entry keeps its kind', () {
    // The kind is in the url, so opening a manga must not land on the anime
    // record with the same MAL id — they are different titles.
    final c = canonicalOf(_stub(malId: 11, type: ProviderType.manga))!;
    expect(ZmodeIds.showUrl(c), 'zm://manga/mal:11');
  });

  test('a novel entry keeps its kind', () {
    final c = canonicalOf(_stub(malId: 12, type: ProviderType.novel))!;
    expect(ZmodeIds.showUrl(c), 'zm://novel/mal:12');
  });

  test('a Simkl series uses the tv namespace', () {
    // TMDB ids are namespaced: /tv/9 and /movie/9 are different titles, so
    // getting this wrong opens the wrong record or none.
    final c = canonicalOf(_stub(tmdbId: 9, tmdbIsTv: true, type: ProviderType.movie))!;
    expect(ZmodeIds.showUrl(c), 'zm://tv/tmdb:9');
  });

  test('a Simkl film uses the movie namespace', () {
    final c = canonicalOf(_stub(tmdbId: 9, type: ProviderType.movie))!;
    expect(ZmodeIds.showUrl(c), 'zm://movie/tmdb:9');
  });

  test('an entry with no id at all still falls back to search', () {
    expect(canonicalOf(_stub()), isNull);
  });
}
