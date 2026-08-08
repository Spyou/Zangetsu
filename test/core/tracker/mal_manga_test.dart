import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/mal_service.dart';
import 'package:watch_app/core/tracker/tracker.dart';

// Golden strings: the EXACT path text mal_service.dart sent for anime before
// this file existed — copied verbatim (not retyped) from the pre-refactor
// source at the cited line numbers, with a representative title/id/query so
// the interpolation is fully resolved. Same technique as Task 15's
// anilist_manga_test.dart: pin the anime text byte-for-byte first, so a
// change to any of these fails loudly — MediaKind.manga must not perturb the
// anime request by one byte.
//
// mal_service.dart:243 — `_resolve`'s title-search GET.
const _searchAnimeGolden = 'anime?q=Naruto&limit=1&fields=num_episodes';
// mal_service.dart:271 — `_totalEpisodes`'s by-id GET.
const _totalAnimeGolden = 'anime/21?fields=num_episodes';
// mal_service.dart:508 (fetchEntry) — the single-entry read GET.
const _entryAnimeGolden = 'anime/21?fields=num_episodes,my_list_status';
// mal_service.dart:568-569 (searchEntries) — the match-fixer search GET.
const _searchEntriesAnimeGolden =
    'anime?q=Naruto&limit=12&fields=num_episodes,media_type,start_season,main_picture';
// mal_service.dart:309/404 (_patch / removeFromList) — my_list_status path.
const _listStatusAnimeGolden = 'anime/21/my_list_status';
// mal_service.dart:598-600 (fetchList) — the whole-library read GET, verbatim
// from the pre-manga source. `media_type` is NOT selected: it only exists on
// the manga variant, so the anime request must not grow a field.
const _userListAnimeGolden =
    'users/@me/animelist'
    '?fields=list_status,num_episodes,main_picture&limit=1000&nsfw=true';

/// One page of a MAL user-list response, shaped like the real envelope:
/// `data[].node` + `data[].list_status`, with `paging` for the next page.
Map<String, dynamic> _page(List<Map<String, dynamic>> data) => {
  'data': data,
  'paging': <String, dynamic>{},
};

Map<String, dynamic> _row({
  required int id,
  required String title,
  required String status,
  String? mediaType,
  int? watched,
  int? read,
  num? score,
}) => {
  'node': {
    'id': id,
    'title': title,
    'main_picture': {
      'medium': 'https://cdn.myanimelist.net/$id-m.jpg',
      'large': 'https://cdn.myanimelist.net/$id-l.jpg',
    },
    'media_type': ?mediaType,
  },
  'list_status': {
    'status': status,
    'score': score ?? 0,
    // MAL's ASYMMETRY: the anime GET answers with `num_episodes_watched`
    // (the PATCH body key is `num_watched_episodes`); manga answers with
    // `num_chapters_read`, the same name it accepts on a write.
    'num_episodes_watched': ?watched,
    'num_chapters_read': ?read,
  },
};

void main() {
  group('anime paths — golden (byte-identical to pre-Task-16 text)', () {
    test('malSearchPath', () {
      expect(malSearchPath(MediaKind.anime, 'Naruto'), _searchAnimeGolden);
    });

    test('malTotalPath', () {
      expect(malTotalPath(MediaKind.anime, 21), _totalAnimeGolden);
    });

    test('malEntryPath', () {
      expect(malEntryPath(MediaKind.anime, 21), _entryAnimeGolden);
    });

    test('malSearchEntriesPath', () {
      expect(
        malSearchEntriesPath(MediaKind.anime, 'Naruto'),
        _searchEntriesAnimeGolden,
      );
    });

    test('malListStatusPath', () {
      expect(malListStatusPath(MediaKind.anime, 21), _listStatusAnimeGolden);
    });

    test('malUserListPath', () {
      expect(malUserListPath(MediaKind.anime), _userListAnimeGolden);
    });

    test(
      'malProgressField (WRITE / PATCH body key) is num_watched_episodes',
      () {
        expect(malProgressField(MediaKind.anime), 'num_watched_episodes');
      },
    );

    // Round-1 review regression: MAL's anime API is asymmetric — the PATCH
    // body key is `num_watched_episodes` but the `my_list_status` GET
    // response uses `num_episodes_watched`. Collapsing these into one
    // builder made fetchEntry().progress permanently null for anime (and,
    // worse, let a stray "+1" tap PATCH progress:1 over a real count). This
    // pin fails the moment the two builders return the same string for
    // anime — see the round-1 fix report for the before/after run proving
    // it catches exactly that collapse.
    test(
      'malProgressReadField (my_list_status GET field) is '
      'num_episodes_watched — asymmetric from the write field for anime',
      () {
        expect(malProgressReadField(MediaKind.anime), 'num_episodes_watched');
        expect(
          malProgressReadField(MediaKind.anime),
          isNot(malProgressField(MediaKind.anime)),
        );
      },
    );

    test(
      'malStatusFor(reading: false) is byte-identical to WatchStatusX.mal',
      () {
        for (final s in WatchStatus.values) {
          expect(malStatusFor(s, reading: false), s.mal);
        }
      },
    );
  });

  group('manga/novel paths — /v2/manga, num_chapters not num_episodes', () {
    test('malSearchPath', () {
      expect(
        malSearchPath(MediaKind.manga, 'Naruto'),
        'manga?q=Naruto&limit=1&fields=num_chapters',
      );
    });

    test('malTotalPath', () {
      expect(malTotalPath(MediaKind.manga, 21), 'manga/21?fields=num_chapters');
    });

    test('malEntryPath', () {
      expect(
        malEntryPath(MediaKind.manga, 21),
        'manga/21?fields=num_chapters,my_list_status',
      );
    });

    test('malSearchEntriesPath', () {
      expect(
        malSearchEntriesPath(MediaKind.manga, 'Naruto'),
        'manga?q=Naruto&limit=12&fields=num_chapters,media_type,start_season,main_picture',
      );
    });

    test('malListStatusPath', () {
      expect(malListStatusPath(MediaKind.manga, 21), 'manga/21/my_list_status');
    });

    test('malUserListPath hits /mangalist and asks for media_type', () {
      final p = malUserListPath(MediaKind.manga);
      expect(
        p,
        'users/@me/mangalist'
        '?fields=list_status,num_chapters,main_picture,media_type'
        '&limit=1000&nsfw=true',
      );
      // Without media_type there is no way to tell a light novel from a manga.
      expect(p, contains('media_type'));
      expect(p, isNot(contains('num_episodes')));
    });

    test('malProgressField is num_chapters_read', () {
      expect(malProgressField(MediaKind.manga), 'num_chapters_read');
    });

    test(
      'malProgressReadField equals the write field for manga '
      '(num_chapters_read is both the read and write name)',
      () {
        expect(malProgressReadField(MediaKind.manga), 'num_chapters_read');
        expect(
          malProgressReadField(MediaKind.manga),
          malProgressField(MediaKind.manga),
        );
      },
    );

    test(
      'malStatusFor(reading: true): watching→reading, planning→plan_to_read',
      () {
        expect(malStatusFor(WatchStatus.watching, reading: true), 'reading');
        expect(
          malStatusFor(WatchStatus.planning, reading: true),
          'plan_to_read',
        );
      },
    );

    test(
      'malStatusFor(reading: true): completed/paused/dropped are shared',
      () {
        expect(
          malStatusFor(WatchStatus.completed, reading: true),
          WatchStatus.completed.mal,
        );
        expect(
          malStatusFor(WatchStatus.paused, reading: true),
          WatchStatus.paused.mal,
        );
        expect(
          malStatusFor(WatchStatus.dropped, reading: true),
          WatchStatus.dropped.mal,
        );
      },
    );
  });

  group('malWatchStatus — MAL has two status vocabularies', () {
    test('anime words map to the same statuses they always did', () {
      expect(malWatchStatus('watching'), WatchStatus.watching);
      expect(malWatchStatus('plan_to_watch'), WatchStatus.planning);
      expect(malWatchStatus('completed'), WatchStatus.completed);
      expect(malWatchStatus('on_hold'), WatchStatus.paused);
      expect(malWatchStatus('dropped'), WatchStatus.dropped);
    });

    test('manga words (reading/plan_to_read) map too', () {
      expect(malWatchStatus('reading'), WatchStatus.watching);
      expect(malWatchStatus('plan_to_read'), WatchStatus.planning);
    });

    test('an unknown/null status is null — the caller skips that entry', () {
      expect(malWatchStatus(null), isNull);
      expect(malWatchStatus('rereading'), isNull);
      expect(malWatchStatus(''), isNull);
    });

    test('every status we WRITE for manga can be READ back', () {
      // Round-trip guard: if malStatusFor ever emits a word malWatchStatus
      // doesn't know, that entry would silently vanish from the import.
      for (final s in WatchStatus.values) {
        expect(
          malWatchStatus(malStatusFor(s, reading: true)),
          s,
          reason: 'manga status "${malStatusFor(s, reading: true)}"',
        );
        expect(malWatchStatus(malStatusFor(s, reading: false)), s);
      }
    });
  });

  group('malProviderType — novels ride on the MAL manga list', () {
    test('anime kind ignores media_type entirely', () {
      for (final t in [null, 'tv', 'movie', 'novel']) {
        expect(malProviderType(MediaKind.anime, t), ProviderType.anime);
      }
    });

    test('novel / light_novel media types are novels', () {
      expect(malProviderType(MediaKind.manga, 'novel'), ProviderType.novel);
      expect(
        malProviderType(MediaKind.manga, 'light_novel'),
        ProviderType.novel,
      );
    });

    test('every other reading media type (incl. unknown/null) is manga', () {
      for (final t in [null, 'manga', 'manhwa', 'manhua', 'one_shot', 'oel']) {
        expect(
          malProviderType(MediaKind.manga, t),
          ProviderType.manga,
          reason: 'media_type "$t" must stay visible in manga mode',
        );
      }
    });
  });

  group('parseMalListPage — anime path (unchanged behaviour)', () {
    final page = _page([
      _row(
        id: 21,
        title: 'One Piece',
        status: 'watching',
        watched: 1084,
        score: 9,
      ),
      _row(id: 5114, title: 'Fullmetal Alchemist: Brotherhood',
          status: 'plan_to_watch', watched: 0, score: 0),
    ]);

    test('parses episodes/status/score into anime-typed stubs', () {
      final out = parseMalListPage(page, MediaKind.anime);
      expect(out.length, 2);

      final onePiece = out.first;
      expect(onePiece.item.title, 'One Piece');
      expect(onePiece.item.type, ProviderType.anime);
      expect(onePiece.item.malId, 21);
      expect(onePiece.item.id, 'tracker:mal:21');
      expect(onePiece.item.cover, 'https://cdn.myanimelist.net/21-l.jpg');
      expect(onePiece.status, WatchStatus.watching);
      expect(onePiece.progress, 1084);
      expect(onePiece.score, 9.0);

      final fma = out.last;
      expect(fma.status, WatchStatus.planning);
      expect(fma.progress, 0);
      expect(fma.score, isNull); // 0 = unrated
    });

    test('progress is read from num_episodes_watched, not the write name', () {
      // The asymmetry that already burned this codebase once: a row that
      // only carries the PATCH-body name must NOT be read as progress.
      final out = parseMalListPage(
        _page([
          {
            'node': {'id': 21, 'title': 'One Piece'},
            'list_status': {
              'status': 'watching',
              'num_watched_episodes': 1084, // write name — wrong for a GET
            },
          },
        ]),
        MediaKind.anime,
      );
      expect(out.single.progress, isNull);
    });

    test('an unmappable status is skipped, not defaulted', () {
      final out = parseMalListPage(
        _page([
          _row(id: 1, title: 'Bad', status: 'rewatching', watched: 3),
          _row(id: 2, title: 'Good', status: 'dropped', watched: 3),
        ]),
        MediaKind.anime,
      );
      expect(out.length, 1);
      expect(out.single.item.malId, 2);
    });

    test('a malformed body yields an empty list rather than throwing', () {
      expect(parseMalListPage(null, MediaKind.anime), isEmpty);
      expect(parseMalListPage('nope', MediaKind.anime), isEmpty);
      expect(parseMalListPage({'data': null}, MediaKind.anime), isEmpty);
      expect(parseMalListPage({'data': <dynamic>[]}, MediaKind.anime), isEmpty);
    });
  });

  group('parseMalListPage — manga list splits manga from novel', () {
    final page = _page([
      _row(
        id: 13,
        title: 'One Piece',
        status: 'reading',
        mediaType: 'manga',
        read: 1120,
        score: 10,
      ),
      _row(
        id: 21,
        title: 'Death Note',
        status: 'completed',
        mediaType: 'manga',
        read: 108,
      ),
      _row(
        id: 9115,
        title: 'Mushoku Tensei',
        status: 'plan_to_read',
        mediaType: 'light_novel',
        read: 47,
      ),
    ]);

    late List<TrackerListItem> out;
    setUp(() => out = parseMalListPage(page, MediaKind.manga));

    test('a manga row lands in manga with chapters as progress', () {
      final manga = out.firstWhere((e) => e.item.malId == 13);
      expect(manga.item.type, ProviderType.manga);
      expect(manga.item.title, 'One Piece');
      expect(manga.status, WatchStatus.watching); // "reading"
      expect(manga.progress, 1120); // chapters read, not episodes
      expect(manga.score, 10.0);
    });

    test('a light_novel row lands in NOVEL, not manga', () {
      final novel = out.firstWhere((e) => e.item.malId == 9115);
      expect(novel.item.type, ProviderType.novel);
      expect(novel.item.type, isNot(ProviderType.manga));
      expect(novel.status, WatchStatus.planning); // "plan_to_read"
      expect(novel.progress, 47);
    });

    test('reading ids are namespaced away from the anime id space', () {
      // MAL id 21 is Death Note as a manga and One Piece as an anime.
      final manga21 = out.firstWhere((e) => e.item.malId == 21);
      expect(manga21.item.id, 'tracker:mal:manga:21');
      expect(manga21.item.id, isNot('tracker:mal:21'));
      expect(manga21.item.type, ProviderType.manga);
    });

    test('a manga row carrying only num_episodes_watched has no progress', () {
      // Proves the read field is kind-aware rather than hardcoded to anime's.
      final wrong = parseMalListPage(
        _page([
          _row(id: 13, title: 'One Piece', status: 'reading', watched: 1120),
        ]),
        MediaKind.manga,
      );
      expect(wrong.single.progress, isNull);
    });
  });

  group(
    'id-space isolation (manga resolver cache must not touch the anime one)',
    () {
      test('malRoot picks the right list root', () {
        expect(malRoot(MediaKind.anime), 'anime');
        expect(malRoot(MediaKind.manga), 'manga');
      });
    },
  );
}
