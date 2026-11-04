import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/player/watch_page_info.dart';

Episode _ep({
  String title = '',
  double? number,
  int? season,
  String? description,
  String? metaTitle,
}) => Episode(
  id: 'e$number',
  title: title,
  number: number,
  url: 'https://x/$number',
  season: season,
  description: description,
  metaTitle: metaTitle,
);

void main() {
  group('watch time format', () {
    test('pads minutes and seconds', () {
      expect(formatWatchTime(const Duration(seconds: 0)), '00:00');
      expect(formatWatchTime(const Duration(minutes: 3, seconds: 7)), '03:07');
      expect(
        formatWatchTime(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });
  });
  group('watch page header', () {
    test('show snapshot fills a missing episode description', () {
      final h = resolveWatchPageHeader(
        episode: _ep(title: 'T', number: 1),
        showTitle: 'Show',
        showDescription: 'The show saga.',
      );
      expect(h.description, 'The show saga.');
    });

    test('episode description wins over the show snapshot', () {
      final h = resolveWatchPageHeader(
        episode: _ep(title: 'T', number: 1, description: 'This episode.'),
        showTitle: 'Show',
        showDescription: 'The show saga.',
      );
      expect(h.description, 'This episode.');
    });

    test('blank snapshot hides the section', () {
      final h = resolveWatchPageHeader(
        episode: _ep(title: 'T', number: 1),
        showDescription: '  ',
      );
      expect(h.description, isNull);
    });

    test('anime episode shows its title with show and S/E line', () {
      final h = resolveWatchPageHeader(
        episode: _ep(title: 'The Fall', number: 1, season: 1),
        showTitle: 'Attack on Titan',
      );
      expect(h.title, 'The Fall');
      expect(h.subtitle, 'Attack on Titan · S1 E1');
    });

    test('generic source titles fall back to Episode N', () {
      final h = resolveWatchPageHeader(
        episode: _ep(title: 'Episode 12', number: 12),
        showTitle: 'Show',
      );
      expect(h.title, 'Episode 12');
    });

    test('S1 E3 prefixes are cleaned from the title', () {
      final h = resolveWatchPageHeader(
        episode: _ep(title: 'S1 E3 - The Choice', number: 3, season: 1),
        showTitle: 'Show',
      );
      expect(h.title, 'The Choice');
      expect(h.subtitle, 'Show · S1 E3');
    });

    test('movie without a number shows no episode label', () {
      final h = resolveWatchPageHeader(
        episode: _ep(title: 'The Movie'),
        showTitle: 'The Movie',
      );
      expect(h.title, 'The Movie');
      expect(h.subtitle, 'The Movie');
    });

    test('missing season shows only the episode number', () {
      final h = resolveWatchPageHeader(
        episode: _ep(title: 'Real Title', number: 5),
        showTitle: 'Show',
      );
      expect(h.subtitle, 'Show · E5');
    });

    test('empty description hides the section', () {
      expect(
        resolveWatchPageHeader(episode: _ep(title: 'T', number: 1)).description,
        isNull,
      );
      expect(
        resolveWatchPageHeader(
          episode: _ep(title: 'T', number: 1, description: '  '),
        ).description,
        isNull,
      );
      expect(
        resolveWatchPageHeader(
          episode: _ep(title: 'T', number: 1, description: 'A great ep.'),
        ).description,
        'A great ep.',
      );
    });
  });
}
