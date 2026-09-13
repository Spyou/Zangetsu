import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/metadata/episode_metadata_service.dart';
import 'package:watch_app/core/models/episode.dart';

void main() {
  test('copyWith fills extras, preserves untouched fields', () {
    const e = Episode(id: 'a', title: 'Ep', number: 1, url: 'u', season: 2);
    final e2 = e.copyWith(
      description: 'A synopsis.',
      metaTitle: 'Real Title',
      thumbnail: 'still.jpg',
      date: '2024-01-01',
      rating: 8.1,
      runtimeMinutes: 24,
    );
    expect(e2.description, 'A synopsis.');
    expect(e2.metaTitle, 'Real Title');
    expect(e2.thumbnail, 'still.jpg');
    expect(e2.date, '2024-01-01');
    expect(e2.rating, 8.1);
    expect(e2.runtimeMinutes, 24);
    expect(e2.id, 'a');
    expect(e2.season, 2);
    expect(e.description, isNull); // original untouched
  });

  group('parseAniZip', () {
    test('maps number -> full meta (rating string -> double)', () {
      final m = EpisodeMetadataService.parseAniZip({
        'episodes': {
          '1': {
            'title': {'en': 'The Start', 'x-jat': 'Hajimari'},
            'overview': 'First ep.',
            'image': 'https://x/still1.jpg',
            'rating': '8.02',
            'runtime': 26,
            'airDate': '2023-09-29',
          },
          '2': {'overview': '   '}, // all blank -> dropped
        }
      });
      expect(m[1]?.title, 'The Start');
      expect(m[1]?.overview, 'First ep.');
      expect(m[1]?.image, 'https://x/still1.jpg');
      expect(m[1]?.rating, closeTo(8.02, 0.001));
      expect(m[1]?.runtime, 26);
      expect(m[1]?.airDate, '2023-09-29');
      expect(m.containsKey(2), isFalse);
    });
    test('title-only episode is kept, zero rating dropped', () {
      final m = EpisodeMetadataService.parseAniZip({
        'episodes': {
          '1': {
            'title': {'en': 'Named'},
            'rating': '0',
          },
        }
      });
      expect(m[1]?.title, 'Named');
      expect(m[1]?.rating, isNull);
    });

    // AniZip only fills `overview` on early episodes for long shows (Naruto
    // Shippuden: 1–32). The rest ship `summary` only — without this fallback
    // ranges 51–100+ look bare (no description) even when titles exist.
    test('summary fills overview when overview is absent', () {
      final m = EpisodeMetadataService.parseAniZip({
        'episodes': {
          '51': {
            'title': {'en': 'Reunion'},
            'summary': 'Team Kakashi learns Sai`s true mission.',
          },
          '1': {
            'title': {'en': 'Homecoming'},
            'overview': 'Prefer overview when both exist.',
            'summary': 'Ignored summary.',
          },
        },
      });
      expect(m[51]?.title, 'Reunion');
      expect(m[51]?.overview, 'Team Kakashi learns Sai`s true mission.');
      expect(m[1]?.overview, 'Prefer overview when both exist.');
    });

    test('reads themoviedb_id from mappings', () {
      expect(
        EpisodeMetadataService.parseAniZipTmdbId({
          'mappings': {'themoviedb_id': '31910'},
        }),
        31910,
      );
      expect(
        EpisodeMetadataService.parseAniZipTmdbId({
          'mappings': {'themoviedb_id': 1429},
        }),
        1429,
      );
      expect(EpisodeMetadataService.parseAniZipTmdbId({'episodes': {}}), isNull);
    });

    test('non-map / missing episodes -> empty', () {
      expect(EpisodeMetadataService.parseAniZip(null), isEmpty);
      expect(EpisodeMetadataService.parseAniZip({'x': 1}), isEmpty);
    });
  });

  group('absoluteEpisodeNumber', () {
    // Shippuden-style: S2 episode_number continues from 33.
    test('continuous numbering across seasons', () {
      expect(
        EpisodeMetadataService.absoluteEpisodeNumber(
          seasonEpisodeNumber: 33,
          seasonEpisodeCount: 21,
          absoluteBase: 32,
          minNumInSeason: 33,
          maxNumInSeason: 53,
        ),
        33,
      );
    });

    // Attack on Titan-style: each season restarts at 1.
    test('per-season numbering uses absoluteBase', () {
      expect(
        EpisodeMetadataService.absoluteEpisodeNumber(
          seasonEpisodeNumber: 1,
          seasonEpisodeCount: 12,
          absoluteBase: 25,
          minNumInSeason: 1,
          maxNumInSeason: 12,
        ),
        26,
      );
    });
  });

  group('parseTmdbSeason', () {
    test('maps episode_number -> full meta, builds still URL', () {
      final m = EpisodeMetadataService.parseTmdbSeason({
        'episodes': [
          {
            'episode_number': 1,
            'name': 'Pilot',
            'overview': 'Pilot ep.',
            'still_path': '/abc.jpg',
            'vote_average': 7.4,
            'runtime': 42,
            'air_date': '2020-05-01',
          },
          {'episode_number': 2, 'name': '', 'overview': ''}, // dropped
        ]
      });
      expect(m[1]?.title, 'Pilot');
      expect(m[1]?.image, 'https://image.tmdb.org/t/p/w300/abc.jpg');
      expect(m[1]?.rating, 7.4);
      expect(m[1]?.runtime, 42);
      expect(m[1]?.airDate, '2020-05-01');
      expect(m.containsKey(2), isFalse);
    });
  });

  group('mergeMeta', () {
    final byNum = <int, EpisodeMeta>{
      1: (
        title: 'One',
        overview: 'one',
        image: 'meta-still.jpg',
        rating: 8.0,
        runtime: 24,
        airDate: '2024-01-02',
      ),
    };

    test('fills still/date only when the source left them empty', () {
      const eps = [
        Episode(id: '1', title: 'A', number: 1, url: 'u1'), // no thumb/date
        Episode(
          id: '1b',
          title: 'A',
          number: 1,
          url: 'u1',
          thumbnail: 'src-still.jpg', // source has its own
          date: '2024-09-09',
        ),
      ];
      final out = mergeMeta(eps, (e) => byNum[e.number?.toInt()]);
      // Empty source -> filled from meta.
      expect(out[0].thumbnail, 'meta-still.jpg');
      expect(out[0].date, '2024-01-02');
      expect(out[0].metaTitle, 'One');
      expect(out[0].rating, 8.0);
      expect(out[0].runtimeMinutes, 24);
      // Source already had its own -> kept.
      expect(out[1].thumbnail, 'src-still.jpg');
      expect(out[1].date, '2024-09-09');
    });

    test('no matches returns the same list instance', () {
      const eps = [Episode(id: '9', title: 'Z', number: 9, url: 'u9')];
      expect(identical(mergeMeta(eps, (_) => null), eps), isTrue);
    });
  });
}
