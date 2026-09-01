import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

void main() {
  const fma = ZCanonical(ZKind.anime, 'mal:5114');
  const dune = ZCanonical(ZKind.movie, 'tmdb:438631');

  test('show url round-trips', () {
    final url = ZmodeIds.showUrl(fma);
    expect(url, 'zm://anime/mal:5114');
    expect(ZmodeIds.isZ(url), isTrue);
    expect(ZmodeIds.parseShow(url), fma);
  });

  test('episode url round-trips', () {
    final url = ZmodeIds.episodeUrl(dune, 1);
    expect(url, 'zm://movie/tmdb:438631/ep/1');
    final p = ZmodeIds.parseEpisode(url);
    expect(p?.show, dune);
    expect(p?.episode, 1);
  });

  test('parseShow accepts an episode url and drops the episode', () {
    expect(ZmodeIds.parseShow('zm://anime/mal:5114/ep/7'), fma);
  });

  test('foreign urls are not ours', () {
    expect(ZmodeIds.isZ('https://allanime.to/anime/x'), isFalse);
    expect(ZmodeIds.parseShow('https://allanime.to/anime/x'), isNull);
    expect(ZmodeIds.parseEpisode('zm://anime/mal:5114'), isNull);
    expect(ZmodeIds.parseShow('zm://dragon/mal:1'), isNull);
  });

  test('key is stable', () {
    expect(fma.key, 'anime:mal:5114');
  });
}
