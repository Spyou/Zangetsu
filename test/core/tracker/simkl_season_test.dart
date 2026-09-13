import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/tracker/simkl_service.dart';

/// Simkl keeps a series as ONE entry with seasons inside it, so an episode
/// number on its own can't say which season — S3E3 and S1E3 are both "3".
/// Every scrobble used to send the bare number, which is why a multi-season
/// series looked stuck on whatever the app last wrote.
///
/// The season is only safe to send in one specific case, and these pin down
/// which. The flat cases matter as much as the seasoned one: they are the
/// shape that works TODAY, and sending a season there would break it.
void main() {
  List<dynamic> seasons(Map<String, dynamic> b) =>
      (b['seasons'] as List?) ?? const [];
  List<dynamic> episodes(Map<String, dynamic> b) =>
      (b['episodes'] as List?) ?? const [];

  group('a real season on a series', () {
    test('is sent as a season wrapping the episode', () {
      final b = SimklService.watchedBody(19, 3, 3, null);
      expect(seasons(b), hasLength(1));
      expect(seasons(b).first['number'], 3);
      // 1..3 of THAT season, not the source's 19 — see _upTo.
      expect(
        (seasons(b).first['episodes'] as List).map((e) => e['number']),
        [1, 2, 3],
      );
      expect(b.containsKey('episodes'), isFalse,
          reason: 'both shapes at once would be ambiguous');
    });

    test('season 1 is still stated rather than left implied', () {
      // Leaving it out is what made everything pile into one season; if we
      // know it, say it.
      final b = SimklService.watchedBody(5, 1, 5, null);
      expect(seasons(b).first['number'], 1);
      expect((seasons(b).first['episodes'] as List), hasLength(5));
    });
  });

  group('keeps the flat shape — these work today and must not change', () {
    test('no season reported by the source', () {
      final b = SimklService.watchedBody(7, null, null, null);
      expect(episodes(b).map((e) => e['number']), [1, 2, 3, 4, 5, 6, 7]);
      expect(b.containsKey('seasons'), isFalse);
    });

    test('a MAL id, even with a season in hand', () {
      // A MAL id resolves to a season-specific anime entry whose episodes
      // start at 1 — "season 3" is meaningless against it, and sending one
      // would break the anime path that is correct today.
      final b = SimklService.watchedBody(3, 3, 3, 52991);
      expect(episodes(b).map((e) => e['number']), [1, 2, 3]);
      expect(b.containsKey('seasons'), isFalse);
    });

    test('a nonsense season is ignored rather than written', () {
      for (final bad in [0, -1]) {
        final b = SimklService.watchedBody(4, bad, 4, null);
        expect(b.containsKey('seasons'), isFalse, reason: 'season $bad');
        expect(episodes(b).last['number'], 4);
      }
    });

    test('a season with no known position inside it', () {
      // The TV path has the episode but not the list it came from, so it can
      // only offer a season. Guessing the position from the source's own
      // number is what sent "season 3 episode 19".
      final b = SimklService.watchedBody(19, 3, null, null);
      expect(b.containsKey('seasons'), isFalse);
      expect(episodes(b).last['number'], 19);
    });
  });

  group('progress — Simkl counts distinct episodes, not a high-water mark', () {
    test('every episode up to the one watched is included', () {
      // Sending only episode 8 left an account eight episodes in reading
      // "Watching · 1", because Simkl counts what it was told about.
      final b = SimklService.watchedBody(8, null, null, 20);
      expect(episodes(b), hasLength(8));
      expect(episodes(b).first['number'], 1);
      expect(episodes(b).last['number'], 8);
    });

    test('the first episode is just itself', () {
      expect(SimklService.watchedBody(1, null, null, null)['episodes'],
          [{'number': 1}]);
    });

    test('a long-runner is still one request', () {
      final b = SimklService.watchedBody(1177, null, null, null);
      expect(episodes(b), hasLength(1177));
      expect(episodes(b).last['number'], 1177);
    });
  });

  group('seasonEpisodeOf', () {
    Episode ep(String id, int n, int? season) =>
        Episode(id: id, title: id, number: n.toDouble(), url: id, season: season);

    test('a season numbered continuously still counts from 1', () {
      // The real shape that broke this: Reacher on CS · MovieBox numbers
      // season 3 as 17-24, so "19. Number 2 with a Bullet" is episode THREE.
      final eps = [
        for (var i = 1; i <= 8; i++) ep('s1e$i', i, 1),
        for (var i = 9; i <= 16; i++) ep('s2e$i', i, 2),
        for (var i = 17; i <= 24; i++) ep('s3e$i', i, 3),
      ];
      expect(seasonEpisodeOf(eps, eps.firstWhere((e) => e.id == 's3e19')), 3);
      expect(seasonEpisodeOf(eps, eps.firstWhere((e) => e.id == 's3e17')), 1);
      expect(seasonEpisodeOf(eps, eps.firstWhere((e) => e.id == 's3e24')), 8);
    });

    test('a season already numbered from 1 is unchanged', () {
      final eps = [for (var i = 1; i <= 8; i++) ep('e$i', i, 3)];
      expect(seasonEpisodeOf(eps, eps[2]), 3);
    });

    test('null when the episode reports no season', () {
      final eps = [ep('a', 1, null), ep('b', 2, null)];
      expect(seasonEpisodeOf(eps, eps[1]), isNull);
    });

    test('null when the episode is not in the list', () {
      final eps = [ep('a', 1, 1)];
      expect(seasonEpisodeOf(eps, ep('stranger', 9, 1)), isNull);
    });
  });
}
