import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/playback/resume_store.dart';
import 'package:watch_app/features/player/player_screen.dart';

void main() {
  PlayerScreen screen({bool? movie, bool tv = false}) => PlayerScreen(
    sourceId: 'test',
    episodes: const [
      Episode(id: '1', title: 'Episode 1', number: 1, url: '/1'),
    ],
    startIndex: 0,
    resume: ResumeStore(),
    resolveSources: (_) async => [],
    tmdbId: 9,
    tmdbIsTv: tv,
    isMovie: movie,
  );

  test(
    'history/download player context recognizes an existing TMDB movie id',
    () {
      expect(screen().isMovie, isTrue);
      expect(screen(tv: true).isMovie, isFalse);
    },
  );
  test('explicit detail metadata wins over a movie fallback', () {
    expect(screen(movie: false).isMovie, isFalse);
  });
}
