import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/features/detail/cubit/detail_cubit.dart';

/// The episode list a TMDB series actually ends up with.
///
/// `MetadataRepository.detail` merges positionally: rows the matched source
/// has come from the source, rows past the end of its list stay as the
/// catalogue's. Only TMDB and CloudStream ever set `Episode.season`, so on any
/// other source the first half carries no season and the tail carries one.
List<Episode> mergedList({
  required int sourceEps,
  required List<int> tmdbSeasonSizes,
  int? sourceSeason,
  String sourceTitle = 'Episode',
}) {
  // Catalogue rows, as TmdbCatalogue._tvEpisodes builds them: seasons in
  // order, numbered continuously across them.
  final catalogue = <Episode>[];
  var n = 0;
  for (var s = 1; s <= tmdbSeasonSizes.length; s++) {
    for (var i = 1; i <= tmdbSeasonSizes[s - 1]; i++) {
      n++;
      catalogue.add(
        Episode(
          id: '$n',
          title: 'S$s · E$i',
          number: n.toDouble(),
          url: 'zm://tv/tmdb:1/ep/$n',
          season: s,
        ),
      );
    }
  }

  final count = catalogue.length > sourceEps ? catalogue.length : sourceEps;
  return [
    for (var i = 0; i < count; i++)
      if (i < sourceEps)
        Episode(
          id: '${i + 1}',
          title: '$sourceTitle ${i + 1}',
          number: (i + 1).toDouble(),
          url: 'zm://tv/tmdb:1/ep/${i + 1}',
          season: sourceSeason,
        )
      else
        catalogue[i],
  ];
}

/// What the screen would show: the season it defaults to, and the rows in it.
/// Mirrors detail_screen.dart / detail_screen_tv.dart.
({int season, List<Episode> shown}) screen(
  List<Episode> eps, {
  int selected = 1,
}) {
  final seasonSet = seasonsOf(eps);
  final multi = seasonSet.length > 1;
  final current = multi
      ? (seasonSet.contains(selected) ? selected : seasonSet.first)
      : 1;
  return (
    season: current,
    shown: multi ? episodesInSeason(eps, current) : eps,
  );
}

void main() {
  group('a TMDB series on a source that reports no season', () {
    test('season 1 is offered, and it holds the playable episodes', () {
      // 3 seasons of 10 announced; the source has the first 10.
      final eps = mergedList(sourceEps: 10, tmdbSeasonSizes: [10, 10, 10]);
      expect(eps.length, 30);

      // Without the `?? 1` this came back {2, 3}: season 1 was missing from
      // the picker entirely, so nothing playable could be reached from it.
      expect(seasonsOf(eps), {1, 2, 3});

      final s = screen(eps);
      expect(s.season, 1);
      expect(s.shown.length, 10);
      // Every row shown is one the source can actually play.
      expect(s.shown.every((e) => e.number! <= 10), isTrue);
    });

    test('a part-covered season 1 keeps its first episodes', () {
      // S1 has 10, S2 has 10; the source only has 3.
      final eps = mergedList(sourceEps: 3, tmdbSeasonSizes: [10, 10]);
      final s = screen(eps);
      expect(s.season, 1);
      // 3 from the source + 7 announced-but-missing, not 7 starting at E4.
      expect(s.shown.length, 10);
      expect(s.shown.first.number, 1);
    });

    test('later seasons still show only what the catalogue announced', () {
      final eps = mergedList(sourceEps: 10, tmdbSeasonSizes: [10, 10, 10]);
      final s = screen(eps, selected: 2);
      expect(s.season, 2);
      expect(s.shown.length, 10);
      expect(s.shown.every((e) => e.number! > 10), isTrue);
    });
  });

  test('a source that DOES report a season is untouched', () {
    final eps = mergedList(
      sourceEps: 10,
      tmdbSeasonSizes: [10, 10, 10],
      sourceSeason: 1,
    );
    expect(seasonsOf(eps), {1, 2, 3});
    final s = screen(eps);
    expect(s.season, 1);
    expect(s.shown.length, 10);
  });

  test('an S<n> title prefix still wins over the default', () {
    final eps = mergedList(
      sourceEps: 10,
      tmdbSeasonSizes: [10, 10, 10],
      sourceTitle: 'S2 E',
    );
    // Parsed from the title, not defaulted to 1.
    expect(episodesInSeason(eps, 1), isEmpty);
    expect(episodesInSeason(eps, 2).length, 20); // 10 source + 10 catalogue
  });

  test('a single-season show never turns on the season picker', () {
    final eps = mergedList(sourceEps: 8, tmdbSeasonSizes: [12]);
    expect(seasonsOf(eps).length, 1);
    final s = screen(eps);
    expect(s.shown.length, 12); // the whole list, unfiltered
  });

  test('an all-season-less list is still one season', () {
    final eps = [
      for (var i = 1; i <= 5; i++)
        Episode(id: '$i', title: 'Episode $i', number: i.toDouble(), url: '$i'),
    ];
    expect(seasonsOf(eps).length, 1);
    expect(screen(eps).shown.length, 5);
  });

  test('an empty list has no seasons', () {
    expect(seasonsOf(const <Episode>[]), isEmpty);
  });
}
