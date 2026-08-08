import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/anilist/anilist_api.dart';
import 'package:watch_app/core/anilist/anilist_service.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';

// Golden strings: the EXACT query text anilist_api.dart sent for anime before
// this file existed. Copied verbatim (not retyped) from the pre-refactor
// source so a change to any of these fails loudly — the whole point of Task
// 15 is that MediaKind.manga must not perturb the anime request by one byte.
const _malIdAnimeGolden =
    r'query($idMal:Int){ Media(idMal:$idMal, type:ANIME){ id episodes } }';
const _searchAnimeGolden =
    r'query($search:String){ Media(search:$search, type:ANIME){ id episodes } }';
const _entryAnimeGolden =
    r'query($id:Int){ Media(id:$id){ episodes '
    r'nextAiringEpisode{ episode airingAt } '
    r'mediaListEntry{ status score(format:POINT_10) progress } } }';
const _searchMediaAnimeGolden =
    r'query($q:String,$n:Int){ Page(perPage:$n){ media(search:$q,type:ANIME){ '
    r'id idMal episodes format seasonYear '
    r'title{ romaji english } coverImage{ medium } } } }';
// anilist_service.dart:352-355 — the fetchList() library read, verbatim from
// the pre-manga source. `format` is NOT selected here: it only exists on the
// manga variant, so the anime request must not grow a field.
const _listCollectionAnimeGolden =
    r'query($u:String){ MediaListCollection(userName:$u, type:ANIME){ '
    r'lists { status entries { status progress score(format:POINT_10) '
    r'media { idMal title { romaji english } coverImage { large } } } } } }';

/// A `MediaListCollection` response shaped exactly like AniList's — two lists
/// (Watching / Planning), the `media` sub-object carrying idMal + titles +
/// coverImage, and (manga only) `format`.
Map<String, dynamic> _collection(List<Map<String, dynamic>> lists) => {
  'data': {
    'MediaListCollection': {'lists': lists},
  },
};

Map<String, dynamic> _entry({
  required String status,
  required int idMal,
  required String romaji,
  String? english,
  String? format,
  int? progress,
  num? score,
}) => {
  'status': status,
  'progress': progress,
  'score': score,
  'media': {
    'idMal': idMal,
    'title': {'romaji': romaji, 'english': english},
    'format': ?format,
    'coverImage': {'large': 'https://img.anili.st/$idMal.jpg'},
  },
};

void main() {
  group('anime queries — golden (byte-identical to pre-Task-15 text)', () {
    test('mediaByMalIdQuery', () {
      expect(mediaByMalIdQuery(MediaKind.anime), _malIdAnimeGolden);
    });

    test('mediaBySearchQuery', () {
      expect(mediaBySearchQuery(MediaKind.anime), _searchAnimeGolden);
    });

    test('mediaEntryQuery', () {
      expect(mediaEntryQuery(MediaKind.anime), _entryAnimeGolden);
    });

    test('searchMediaQuery', () {
      expect(searchMediaQuery(MediaKind.anime), _searchMediaAnimeGolden);
    });

    test('mediaListCollectionQuery', () {
      expect(
        mediaListCollectionQuery(MediaKind.anime),
        _listCollectionAnimeGolden,
      );
    });

    test('searchMediaQuery ignores novelFormat when kind is anime', () {
      // A novel is a manga sub-format on AniList — the flag must be inert
      // outside MediaKind.manga, even if a caller passes it by mistake.
      expect(
        searchMediaQuery(MediaKind.anime, novelFormat: true),
        _searchMediaAnimeGolden,
      );
    });
  });

  group('manga queries — type: MANGA, chapters/volumes not episodes', () {
    test('mediaByMalIdQuery', () {
      final q = mediaByMalIdQuery(MediaKind.manga);
      expect(q, contains('type:MANGA'));
      expect(q, contains('chapters'));
      expect(q, contains('volumes'));
      expect(q, isNot(contains('episodes')));
      expect(q, isNot(contains('type:ANIME')));
    });

    test('mediaBySearchQuery', () {
      final q = mediaBySearchQuery(MediaKind.manga);
      expect(q, contains('type:MANGA'));
      expect(q, contains('chapters'));
      expect(q, contains('volumes'));
      expect(q, isNot(contains('episodes')));
    });

    test('mediaEntryQuery selects chapters+volumes, keeps the rest intact', () {
      final q = mediaEntryQuery(MediaKind.manga);
      expect(q, contains('chapters'));
      expect(q, contains('volumes'));
      expect(q, isNot(contains('episodes')));
      // Everything else about the entry read is unchanged.
      expect(q, contains('nextAiringEpisode{ episode airingAt }'));
      expect(
        q,
        contains('mediaListEntry{ status score(format:POINT_10) progress }'),
      );
    });

    test('searchMediaQuery', () {
      final q = searchMediaQuery(MediaKind.manga);
      expect(q, contains('type:MANGA'));
      expect(q, contains('chapters'));
      expect(q, contains('volumes'));
      expect(q, isNot(contains('episodes')));
      expect(q, isNot(contains('format_in')));
    });

    test('searchMediaQuery(novelFormat: true) adds format_in: [NOVEL]', () {
      final q = searchMediaQuery(MediaKind.manga, novelFormat: true);
      expect(q, contains('type:MANGA'));
      expect(q, contains('format_in:[NOVEL]'));
    });

    test('searchMediaQuery(novelFormat: false) stays plain manga', () {
      final q = searchMediaQuery(MediaKind.manga, novelFormat: false);
      expect(q, isNot(contains('format_in')));
    });

    test('mediaListCollectionQuery asks for type:MANGA and format', () {
      final q = mediaListCollectionQuery(MediaKind.manga);
      expect(q, contains('type:MANGA'));
      // Without `format` there is no way to tell a light novel from a manga.
      expect(q, contains('title { romaji english } format coverImage'));
      expect(q, isNot(contains('type:ANIME')));
    });
  });

  group('aniListProviderType — novels are a MANGA-list format, not a type', () {
    test('anime kind ignores format entirely', () {
      for (final f in [null, 'TV', 'MOVIE', 'NOVEL']) {
        expect(aniListProviderType(MediaKind.anime, f), ProviderType.anime);
      }
    });

    test('format NOVEL on the manga list is a novel', () {
      expect(
        aniListProviderType(MediaKind.manga, 'NOVEL'),
        ProviderType.novel,
      );
    });

    test('every other manga format (incl. unknown/null) is manga', () {
      for (final f in [null, 'MANGA', 'ONE_SHOT', 'SOMETHING_NEW']) {
        expect(
          aniListProviderType(MediaKind.manga, f),
          ProviderType.manga,
          reason: 'format "$f" must stay visible in manga mode',
        );
      }
    });
  });

  group('parseAniListCollection — anime path (unchanged behaviour)', () {
    final response = _collection([
      {
        'status': 'CURRENT',
        'entries': [
          _entry(
            status: 'CURRENT',
            idMal: 21,
            romaji: 'One Piece',
            english: 'One Piece',
            progress: 1084,
            score: 9,
          ),
        ],
      },
      {
        'status': 'PLANNING',
        'entries': [
          _entry(
            status: 'PLANNING',
            idMal: 5114,
            romaji: 'Hagane no Renkinjutsushi: Fullmetal Alchemist',
            english: 'Fullmetal Alchemist: Brotherhood',
            progress: 0,
            score: 0,
          ),
        ],
      },
    ]);

    test('parses episodes/status/score into anime-typed stubs', () {
      final out = parseAniListCollection(response, MediaKind.anime);
      expect(out.length, 2);

      final onePiece = out.first;
      expect(onePiece.item.title, 'One Piece');
      expect(onePiece.item.type, ProviderType.anime);
      expect(onePiece.item.malId, 21);
      expect(onePiece.item.id, 'tracker:anilist:21');
      expect(onePiece.item.cover, 'https://img.anili.st/21.jpg');
      expect(onePiece.status, WatchStatus.watching);
      expect(onePiece.progress, 1084);
      expect(onePiece.score, 9.0);

      final fma = out.last;
      expect(fma.item.type, ProviderType.anime);
      expect(fma.status, WatchStatus.planning);
      expect(fma.progress, 0);
      // A 0 score means "unrated" on AniList, not a real score of zero.
      expect(fma.score, isNull);
    });

    test('a NOVEL format on the anime list still types as anime', () {
      // Defensive: the anime query never selects `format`, but a stray value
      // must not leak an anime entry into novel mode.
      final out = parseAniListCollection(
        _collection([
          {
            'status': 'CURRENT',
            'entries': [
              _entry(
                status: 'CURRENT',
                idMal: 1,
                romaji: 'Cowboy Bebop',
                format: 'NOVEL',
              ),
            ],
          },
        ]),
        MediaKind.anime,
      );
      expect(out.single.item.type, ProviderType.anime);
    });

    test('an unmappable status is skipped, not defaulted', () {
      final out = parseAniListCollection(
        _collection([
          {
            'status': 'CURRENT',
            'entries': [
              _entry(status: 'NOT_A_STATUS', idMal: 21, romaji: 'One Piece'),
              _entry(status: 'REPEATING', idMal: 20, romaji: 'Naruto'),
            ],
          },
        ]),
        MediaKind.anime,
      );
      expect(out.length, 1);
      expect(out.single.item.malId, 20);
      expect(out.single.status, WatchStatus.watching); // REPEATING → watching
    });

    test('a malformed body yields an empty list rather than throwing', () {
      expect(parseAniListCollection(null, MediaKind.anime), isEmpty);
      expect(parseAniListCollection('nope', MediaKind.anime), isEmpty);
      expect(
        parseAniListCollection({'data': null}, MediaKind.anime),
        isEmpty,
      );
    });
  });

  group('parseAniListCollection — manga list splits manga from novel', () {
    final response = _collection([
      {
        'status': 'CURRENT',
        'entries': [
          _entry(
            status: 'CURRENT',
            idMal: 13,
            romaji: 'One Piece',
            english: 'One Piece',
            format: 'MANGA',
            progress: 1120,
            score: 10,
          ),
          _entry(
            status: 'CURRENT',
            idMal: 9115,
            romaji: 'Mushoku Tensei',
            english: 'Mushoku Tensei: Jobless Reincarnation',
            format: 'NOVEL',
            progress: 47,
            score: 8,
          ),
        ],
      },
      {
        'status': 'COMPLETED',
        'entries': [
          _entry(
            status: 'COMPLETED',
            idMal: 21,
            romaji: 'Death Note',
            format: 'ONE_SHOT',
            progress: 108,
          ),
        ],
      },
    ]);

    late List<TrackerListItem> out;
    setUp(() => out = parseAniListCollection(response, MediaKind.manga));

    test('a MANGA-format entry lands in manga with chapters as progress', () {
      final manga = out.firstWhere((e) => e.item.malId == 13);
      expect(manga.item.type, ProviderType.manga);
      expect(manga.item.title, 'One Piece');
      expect(manga.status, WatchStatus.watching);
      expect(manga.progress, 1120); // chapters read, not episodes
      expect(manga.score, 10.0);
    });

    test('a NOVEL-format entry lands in NOVEL, not manga', () {
      final novel = out.firstWhere((e) => e.item.malId == 9115);
      expect(novel.item.type, ProviderType.novel);
      expect(novel.item.type, isNot(ProviderType.manga));
      expect(novel.item.title, 'Mushoku Tensei: Jobless Reincarnation');
      expect(novel.progress, 47);
      expect(novel.status, WatchStatus.watching);
    });

    test('ONE_SHOT (an unrecognised reading format) stays in manga', () {
      final oneShot = out.firstWhere((e) => e.item.malId == 21);
      expect(oneShot.item.type, ProviderType.manga);
      expect(oneShot.status, WatchStatus.completed);
    });

    test('reading ids are namespaced away from the anime id space', () {
      // MAL id 21 is Death Note as a manga and One Piece as an anime — the
      // stub ids must not collide.
      final manga21 = out.firstWhere((e) => e.item.malId == 21);
      expect(manga21.item.id, 'tracker:anilist:manga:21');
      expect(manga21.item.id, isNot('tracker:anilist:21'));
    });

    test('the manga dedupe set does not leak across kinds', () {
      // Same idMal (21) present on both lists: parsed separately, both kept.
      final animeSide = parseAniListCollection(
        _collection([
          {
            'status': 'CURRENT',
            'entries': [
              _entry(status: 'CURRENT', idMal: 21, romaji: 'One Piece'),
            ],
          },
        ]),
        MediaKind.anime,
      );
      expect(animeSide.single.item.type, ProviderType.anime);
      expect(out.any((e) => e.item.malId == 21), isTrue);
    });
  });
}
