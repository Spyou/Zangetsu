import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tracker/simkl_playback_session.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';

void main() {
  test(
    'play, pause, resume and exit report progress without per-tick requests',
    () {
      final events = <(String, double)>[];
      final session = SimklPlaybackSession((action, progress) {
        events.add((action, progress));
      });
      session.update(positionMs: 0, durationMs: 0, playing: true);
      session.update(positionMs: 0, durationMs: 100000, playing: false);
      expect(events, isEmpty);
      session.update(positionMs: 1000, durationMs: 100000, playing: true);
      session.update(positionMs: 2000, durationMs: 100000, playing: true);
      session.update(positionMs: 3000, durationMs: 100000, playing: false);
      session.update(positionMs: 3000, durationMs: 100000, playing: false);
      session.update(positionMs: 3000, durationMs: 100000, playing: true);
      session.stop();
      session.stop();
      expect(events, [('start', 1), ('pause', 3), ('start', 3), ('stop', 3)]);
    },
  );

  test(
    'buffering pauses the timeline and seeking updates the live position',
    () {
      final events = <(String, double)>[];
      final session = SimklPlaybackSession((a, p) => events.add((a, p)));
      session.update(positionMs: 10000, durationMs: 100000, playing: true);
      session.update(positionMs: 10000, durationMs: 100000, playing: false);
      session.update(positionMs: 10000, durationMs: 100000, playing: true);
      session.update(positionMs: 60000, durationMs: 100000, playing: true);
      session.update(
        positionMs: 100000,
        durationMs: 100000,
        playing: false,
        completed: true,
      );
      session.update(positionMs: 0, durationMs: 100000, playing: true);
      expect(events, [
        ('start', 10),
        ('pause', 10),
        ('start', 10),
        ('start', 60),
        ('stop', 100),
      ]);
    },
  );

  test('steady playback refreshes progress every 30 seconds', () {
    final events = <(String, double)>[];
    final session = SimklPlaybackSession((a, p) => events.add((a, p)));
    for (var s = 0; s <= 60; s += 5) {
      session.update(positionMs: s * 1000, durationMs: 600000, playing: true);
    }
    expect(events, [('start', 0), ('start', 5), ('start', 10)]);
  });

  test('a session that never played does not send stop', () {
    final events = <String>[];
    final session = SimklPlaybackSession((a, _) => events.add(a));
    session.stop();
    expect(events, isEmpty);
  });

  test('progress uses the API precision and cannot exceed 100 percent', () {
    final events = <double>[];
    final session = SimklPlaybackSession((_, p) => events.add(p));
    session.update(positionMs: 1000, durationMs: 3000, playing: true);
    session.update(
      positionMs: 5000,
      durationMs: 3000,
      playing: false,
      completed: true,
    );
    expect(events, [33.33, 100]);
  });

  test('invalid duration never sends a misleading progress update', () {
    final events = <(String, double)>[];
    final session = SimklPlaybackSession((a, p) => events.add((a, p)));
    session.update(positionMs: 20000, durationMs: 100000, playing: true);
    session.update(positionMs: 0, durationMs: 0, playing: false);
    session.stop();
    expect(events, [('start', 20), ('stop', 20)]);
  });

  test(
    'live anime reports only the actual episode, not episodes 1 through N',
    () {
      expect(SimklService.playbackBody(malId: 21, episode: 8), {
        'anime': {
          'ids': {'mal': '21'},
        },
        'episode': {'number': 8},
      });
    },
  );

  test('live TV uses the correct position inside a known season', () {
    expect(
      SimklService.playbackBody(
        tmdbId: 123,
        tmdbIsTv: true,
        episode: 19,
        season: 3,
        seasonEpisode: 3,
      ),
      {
        'show': {
          'ids': {'tmdb': '123', 'type': 'tv'},
        },
        'episode': {'season': 3, 'number': 3},
      },
    );
  });

  test('movies do not require an episode and unknown titles are skipped', () {
    expect(SimklService.playbackBody(imdbId: 'tt123'), {
      'movie': {
        'ids': {'imdb': 'tt123'},
      },
    });
    expect(SimklService.playbackBody(episode: 1), isNull);
    expect(SimklService.playbackBody(malId: 21, episode: 0), isNull);
  });
}
