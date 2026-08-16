import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/player_screen.dart';

void main() {
  group('stripEpisodePrefix', () {
    test('drops the word form so the real title gets the line', () {
      expect(
        stripEpisodePrefix("Episode 2: I Suppose You Aren't Aware", 2),
        "I Suppose You Aren't Aware",
      );
      expect(stripEpisodePrefix('Ep.5 - A Pretty Good Deal', 5), 'A Pretty Good Deal');
      expect(stripEpisodePrefix('E12 Arise', 12), 'Arise');
      expect(stripEpisodePrefix('EPISODE 3 — A Thousand Deaths', 3), 'A Thousand Deaths');
      expect(stripEpisodePrefix('Episode 07: Padded', 7), 'Padded');
    });

    test('drops a bare number only when a separator follows it', () {
      expect(stripEpisodePrefix('2. The Rules of the Dungeon', 2), 'The Rules of the Dungeon');
      expect(stripEpisodePrefix('02 - Padded', 2), 'Padded');
      // The guard that matters: without this the title loses its own name.
      expect(stripEpisodePrefix('12 Monkeys', 12), '12 Monkeys');
      expect(stripEpisodePrefix('7 Samurai', 7), '7 Samurai');
    });

    test('leaves a title alone when the number is a different episode', () {
      expect(stripEpisodePrefix('Episode 9: Something', 3), 'Episode 9: Something');
      expect(stripEpisodePrefix('21 Jump Street', 2), '21 Jump Street');
      expect(stripEpisodePrefix('A Thousand Deaths', 3), 'A Thousand Deaths');
    });

    test('returns empty when the title is nothing but the marker', () {
      // The caller falls back to showing just "E2" for these.
      expect(stripEpisodePrefix('Episode 2', 2), '');
      expect(stripEpisodePrefix('  Episode 2  ', 2), '');
      expect(stripEpisodePrefix('E2', 2), '');
    });
  });
}
