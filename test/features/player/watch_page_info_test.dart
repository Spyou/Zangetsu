import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/player/watch_page_info.dart';

Episode _ep({
  String title = '',
  double? number,
  int? season,
  String? description,
  String? metaTitle,
  String? thumbnail,
  String? unavailable,
  int? runtimeMinutes,
  String? date,
}) => Episode(
  id: 'e$number',
  title: title,
  number: number,
  url: 'https://x/$number',
  season: season,
  thumbnail: thumbnail,
  description: description,
  metaTitle: metaTitle,
  unavailable: unavailable,
  runtimeMinutes: runtimeMinutes,
  date: date,
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

  group('watch page episode list', () {
    test('episode numbers survive the mapping for jump-to-episode', () {
      final rows = watchPageEpisodes(
        episodes: [_ep(title: 'A', number: 47)],
        currentIndex: -1,
      );
      expect(rows.single.number, 47);
    });

    test('season chips filter the rows but keep real indices', () {
      final eps = [
        _ep(title: 'A', number: 1, season: 1),
        _ep(title: 'B', number: 17, season: 2),
      ];
      final rows = watchPageEpisodes(episodes: eps, currentIndex: 1, season: 2);
      expect(rows.length, 1);
      expect(rows.single.index, 1);
      expect(rows.single.current, isTrue);
    });

    test('lists every episode detail-style with the playing one marked', () {
      final eps = [
        _ep(title: 'The Fall', number: 1, season: 1),
        _ep(
          title: 'Second',
          number: 2,
          runtimeMinutes: 24,
          date: '2024-01-01',
          description: 'A great second episode.',
        ),
        _ep(title: 'Third', number: 3),
      ];
      final rows = watchPageEpisodes(episodes: eps, currentIndex: 1);
      expect(rows.length, 3);
      expect(rows[0].index, 0);
      expect(rows[0].heading, '1. The Fall');
      expect(rows[0].current, isFalse);
      expect(rows[1].index, 1);
      expect(rows[1].current, isTrue);
      expect(rows[1].meta, '24 min  ·  2024-01-01');
      expect(rows[1].synopsis, 'A great second episode.');
      expect(rows[2].current, isFalse);
    });

    test('generic titles fall back to Episode N', () {
      final rows = watchPageEpisodes(
        episodes: [_ep(title: 'Ep. 3', number: 3)],
        currentIndex: -1,
      );
      expect(rows.single.label, 'Episode 3');
      expect(rows.single.heading, 'Episode 3');
    });

    test('episode art wins, show cover fills the gaps', () {
      final rows = watchPageEpisodes(
        episodes: [
          _ep(title: 'A', number: 1, thumbnail: 'https://x/ep1.jpg'),
          _ep(title: 'B', number: 2),
        ],
        currentIndex: -1,
        coverFallback: 'https://x/cover.jpg',
      );
      expect(rows[0].thumb, 'https://x/ep1.jpg');
      expect(rows[1].thumb, 'https://x/cover.jpg');
    });

    test('the full list always shows, even solo episodes', () {
      final rows = watchPageEpisodes(
        episodes: [_ep(title: 'A', number: 1)],
        currentIndex: 0,
      );
      expect(rows.single.current, isTrue);
    });

    test('known-missing episodes carry their reason', () {
      final rows = watchPageEpisodes(
        episodes: [
          _ep(title: 'A', number: 1, unavailable: 'Not out yet'),
          _ep(title: 'B', number: 2),
        ],
        currentIndex: -1,
      );
      expect(rows[0].unavailableReason, 'Not out yet');
      expect(rows[1].unavailableReason, isNull);
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

    test('a movie row keeps its playback index without episode numbering', () {
      final rows = watchPageEpisodes(
        episodes: const [
          Episode(
            id: 'movie',
            title: 'Episode 1',
            number: 1,
            url: '/movie',
            runtimeMinutes: 110,
          ),
        ],
        currentIndex: 0,
        isMovie: true,
        showTitle: 'Film title',
      );
      expect(rows.single.index, 0);
      expect(rows.single.current, isTrue);
      expect(rows.single.heading, 'Film title');
      expect(rows.single.label, 'Film title');
      expect(rows.single.number, isNull);
      expect(rows.single.meta, '110 min');
      final header = resolveWatchPageHeader(
        episode: const Episode(
          id: 'm',
          title: 'Episode 1',
          number: 1,
          url: '/m',
        ),
        showTitle: 'Film title',
        isMovie: true,
      );
      expect(header.title, 'Film title');
      expect(header.subtitle, isEmpty);
    });

    test('a film shows the movie title with no episode subtitle', () {
      final h = resolveWatchPageHeader(
        episode: const Episode(id: '1', title: 'Suzume', number: 1, url: '/e'),
        showTitle: 'Suzume',
        showDescription: 'A door opens.',
        isMovie: true,
      );
      expect(h.title, 'Suzume');
      expect(h.subtitle, isEmpty);
      expect(h.description, 'A door opens.');
    });

    test('a film with no episode title falls back to the show title', () {
      final h = resolveWatchPageHeader(
        episode: const Episode(id: '1', title: '', number: 1, url: '/e'),
        showTitle: 'Suzume',
        isMovie: true,
      );
      expect(h.title, 'Suzume');
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

  group('ambient mood color', () {
    test('averages the frame then boosts warmth', () {
      // Solid (200, 50, 50): mean 100, chroma x1.5, lifted +22.
      final bytes = ByteData(16);
      for (var i = 0; i < 4; i++) {
        bytes.setUint8(i * 4, 200);
        bytes.setUint8(i * 4 + 1, 50);
        bytes.setUint8(i * 4 + 2, 50);
        bytes.setUint8(i * 4 + 3, 255);
      }
      final c = ambientGlowColor(bytes, 2, 2);
      expect(c.top, const Color(0xFFFF2F2F));
      expect(c.bottom, const Color(0xFF8C1A1A));
    });

    test('empty input stays black', () {
      final c = ambientGlowColor(ByteData(0), 0, 0);
      expect(c.top, const Color(0xFF000000));
      expect(c.bottom, const Color(0xFF000000));
    });
  });
}
