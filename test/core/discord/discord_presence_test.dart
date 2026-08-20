import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/discord/discord_presence.dart';
import 'package:watch_app/core/models/episode.dart';

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000);

  group('discordPlaybackTimestamps', () {
    test('playing with duration yields start+end so Discord can draw a bar', () {
      final ts = discordPlaybackTimestamps(
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 24),
        playing: true,
        now: now,
      );
      expect(ts.startMs, now.millisecondsSinceEpoch - 5 * 60 * 1000);
      expect(ts.endMs, ts.startMs! + 24 * 60 * 1000);
    });

    test('playing with unknown duration is start-only (elapsed, no bar)', () {
      final ts = discordPlaybackTimestamps(
        position: const Duration(seconds: 90),
        duration: Duration.zero,
        playing: true,
        now: now,
      );
      expect(ts.startMs, now.millisecondsSinceEpoch - 90 * 1000);
      expect(ts.endMs, isNull);
    });

    test('paused omits timestamps so the bar does not keep moving', () {
      final ts = discordPlaybackTimestamps(
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 24),
        playing: false,
        now: now,
      );
      expect(ts.startMs, isNull);
      expect(ts.endMs, isNull);
    });
  });

  group('discordEpisodeLabel', () {
    Episode ep({
      String title = '',
      double? number,
      String? metaTitle,
    }) =>
        Episode(id: '1', title: title, url: 'u', number: number, metaTitle: metaTitle);

    test('number plus real title', () {
      expect(
        discordEpisodeLabel(ep(title: 'Episode 47: The Two Chakra Beasts', number: 47)),
        'Episode 47 · The Two Chakra Beasts',
      );
    });

    test('generic source title uses AniZip/TMDB metaTitle', () {
      expect(
        discordEpisodeLabel(ep(title: 'Episode 47', number: 47, metaTitle: 'The Two Chakra Beasts')),
        'Episode 47 · The Two Chakra Beasts',
      );
    });

    test('generic title with no meta is number only', () {
      expect(discordEpisodeLabel(ep(title: 'Episode 4', number: 4)), 'Episode 4');
    });

    test('title only when number is missing', () {
      expect(discordEpisodeLabel(ep(title: 'Movie')), 'Movie');
    });
  });

  group('DiscordActivity', () {
    test('watching payload uses type 3 and both timestamps', () {
      final json = DiscordActivity(
        name: 'Frieren',
        type: 3,
        details: 'Episode 4',
        startMs: 100,
        endMs: 200,
      ).toJson('app');
      expect(json['type'], 3);
      expect(json['name'], 'Frieren');
      expect(json['timestamps'], {'start': 100, 'end': 200});
    });
  });

  group('discordPresenceUpdate', () {
    test('null activity sends an empty list so the profile status drops', () {
      final payload = discordPresenceUpdate(null, 'app');
      expect(payload['activities'], isEmpty);
    });

    test('watching activity is wrapped as the sole presence', () {
      const a = DiscordActivity(name: 'Frieren', type: 3);
      final payload = discordPresenceUpdate(a, 'app');
      expect(payload['activities'], hasLength(1));
      expect((payload['activities'] as List).single['type'], 3);
    });
  });
}
