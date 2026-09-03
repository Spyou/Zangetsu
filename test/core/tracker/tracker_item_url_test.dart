import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/tracker/tracker_item_url.dart';

MediaItem _stub({
  int? malId,
  int? tmdbId,
  bool tmdbIsTv = false,
  ProviderType type = ProviderType.anime,
}) => MediaItem(
  id: 'tracker:x',
  title: 'One Piece',
  cover: 'https://img/c.jpg',
  url: '',
  type: type,
  sourceId: '',
  malId: malId,
  tmdbId: tmdbId,
  tmdbIsTv: tmdbIsTv,
);

void main() {
  test('a MAL id is the anime/manga/novel identity, keyed by provider type',
      () {
    expect(trackerCanonical(_stub(malId: 21)), isNotNull);
    expect(
      trackerCanonical(_stub(malId: 21))!.key,
      'anime:mal:21',
    );
    expect(
      trackerCanonical(_stub(malId: 13, type: ProviderType.manga))!.key,
      'manga:mal:13',
    );
    expect(
      trackerCanonical(_stub(malId: 9, type: ProviderType.novel))!.key,
      'novel:mal:9',
    );
  });

  test('a TMDB id (Simkl) keys by show/movie, honouring tmdbIsTv', () {
    expect(
      trackerCanonical(_stub(tmdbId: 1399, tmdbIsTv: true))!.key,
      'tv:tmdb:1399',
    );
    expect(
      trackerCanonical(_stub(tmdbId: 438631))!.key,
      'movie:tmdb:438631',
    );
  });

  test('a stub with no ids has no identity and no playable form', () {
    final bare = _stub();
    expect(trackerCanonical(bare), isNull);
    expect(playableTrackerItem(bare), isNull);
  });

  test('playableTrackerItem re-keys the stub onto a zm:// url', () {
    final p = playableTrackerItem(
      _stub(malId: 21),
      savedFrom: 'AniList',
    );
    expect(p, isNotNull);
    expect(p!.id, 'mal:21');
    expect(p.url, 'zm://anime/mal:21');
    expect(p.sourceId, 'zm');
    expect(p.title, 'One Piece');
    expect(p.malId, 21);
    expect(p.savedFrom, 'AniList');
  });
}
