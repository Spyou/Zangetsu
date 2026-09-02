// Relations answer "what else is part of this story"; recommendations answer
// "what else might you like". Both land in the Relations tab, so the order and
// the labelling are what keep them readable. Payloads below match what
// graphql.anilist.co actually returns for the extras selection.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/anilist/anilist_api.dart';

Map<String, dynamic> _rec(String english, {String? type = 'ANIME', int? idMal}) => {
  'node': {
    'mediaRecommendation': type == null
        ? null
        : {
            'idMal': idMal,
            'type': type,
            'title': {'romaji': english, 'english': english},
            'coverImage': {'medium': 'https://img/$english.jpg'},
          },
  },
};

Map<String, dynamic> _media({
  List<Map<String, dynamic>> relations = const [],
  List<Map<String, dynamic>> recommendations = const [],
}) => {
  'characters': {'edges': <dynamic>[]},
  'relations': {'edges': relations},
  'recommendations': {'edges': recommendations},
};

void main() {
  final api = AniListApi(Dio(), () => null);

  Map<String, dynamic> relation(String title, String rel) => {
    'relationType': rel,
    'node': {
      'idMal': 1,
      'type': 'ANIME',
      'format': 'TV',
      'title': {'romaji': title, 'english': title},
      'coverImage': {'medium': 'https://img/$title.jpg'},
    },
  };

  test('recommendations follow the relations, never interleaved', () {
    final out = api.parseExtrasForTest(
      _media(
        relations: [relation('Brotherhood', 'ALTERNATIVE')],
        recommendations: [_rec('Hunter x Hunter', idMal: 11061)],
      ),
    );

    expect(out.relations.map((r) => r.title), [
      'Brotherhood',
      'Hunter x Hunter',
    ]);
    expect(out.relations.first.relation, 'Alternative');
    expect(out.relations.last.relation, 'Recommended');
    expect(out.relations.last.malId, 11061);
  });

  test('a title already related is not repeated as a recommendation', () {
    final out = api.parseExtrasForTest(
      _media(
        relations: [relation('Brotherhood', 'SEQUEL')],
        recommendations: [_rec('Brotherhood'), _rec('Soul Eater')],
      ),
    );

    expect(out.relations.map((r) => r.title), ['Brotherhood', 'Soul Eater']);
  });

  test('a deleted recommendation is skipped, not crashed on', () {
    final out = api.parseExtrasForTest(
      _media(recommendations: [_rec('Gone', type: null), _rec('Kept')]),
    );

    expect(out.relations.map((r) => r.title), ['Kept']);
  });

  test('a manga page keeps manga recommendations, an anime page drops them', () {
    final recs = [_rec('Berserk', type: 'MANGA')];

    expect(api.parseExtrasForTest(_media(recommendations: recs)).relations, isEmpty);
    expect(
      api
          .parseExtrasForTest(
            _media(recommendations: recs),
            keepTypes: const {'MANGA', 'ANIME'},
          )
          .relations
          .single
          .title,
      'Berserk',
    );
  });
}
