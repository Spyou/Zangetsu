import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/episode_title.dart';

void main() {
  group('carryEpisodeDisplayMeta', () {
    // Detail paints catalogue/AniZip titles, then the matched source's
    // "Episode N" list lands. Display must stay on the metadata stack.
    test('keeps AniZip names when the source only has Episode N', () {
      final previous = [
        const Episode(
          id: '1',
          title: 'Episode 1',
          number: 1,
          url: 'zm://a/ep/1',
          metaTitle: 'Homecoming',
          description: 'Naruto returns.',
        ),
      ];
      final next = [
        const Episode(
          id: '1',
          title: 'Episode 1',
          number: 1,
          url: 'zm://a/ep/1',
        ),
      ];
      final out = carryEpisodeDisplayMeta(previous, next);
      expect(out.single.metaTitle, 'Homecoming');
      expect(out.single.description, 'Naruto returns.');
    });

    test('does not overwrite a real source title with a generic catalogue one',
        () {
      final previous = [
        const Episode(
          id: '1',
          title: 'Episode 1',
          number: 1,
          url: 'zm://a/ep/1',
        ),
      ];
      final next = [
        const Episode(
          id: '1',
          title: 'The Bridge to Peace',
          number: 1,
          url: 'zm://a/ep/1',
        ),
      ];
      final out = carryEpisodeDisplayMeta(previous, next);
      expect(out.single.title, 'The Bridge to Peace');
    });
  });
}
