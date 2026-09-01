// AniList is the only anime provider that filters server-side, so the query it
// builds is the whole feature. These assert the GraphQL text rather than the
// results: a wrong clause returns an empty list, which looks like "no matches"
// instead of a bug.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/anilist_catalogue.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

void main() {
  late List<String> sent;

  AniListCatalogue catalogue() {
    sent = [];
    return AniListCatalogue((q, v) async {
      sent.add(q);
      return {'Page': {'media': []}};
    });
  }

  test('a plain search sends no filter clauses', () async {
    final c = catalogue();
    await c.searchFiltered('naruto', ZKind.anime);

    expect(sent.single, contains('search:'));
    expect(sent.single, isNot(contains('genre_in')));
    expect(sent.single, isNot(contains('averageScore_greater')));
  });

  test('filters become server-side clauses', () async {
    final c = catalogue();
    await c.searchFiltered('', ZKind.anime, filters: const MetaFilters(
      genres: ['Action', 'Comedy'],
      year: 2023,
      season: MetaSeason.summer,
      status: MetaStatus.finished,
      minScore: 80,
      sort: MetaSort.score,
    ));

    final q = sent.single;
    expect(q, contains('genre_in:["Action","Comedy"]'));
    expect(q, contains('seasonYear:2023'));
    expect(q, contains('season:SUMMER'));
    expect(q, contains('status:FINISHED'));
    expect(q, contains('sort:SCORE_DESC'));
    // averageScore_greater is exclusive, so 80 means "80 and up".
    expect(q, contains('averageScore_greater:79'));
    // No query text at all — filters alone are a browse.
    expect(q, isNot(contains('search:')));
  });

  test('manga keeps its kind format instead of the picked one', () async {
    final c = catalogue();
    await c.searchFiltered('', ZKind.manga,
        filters: const MetaFilters(format: MetaFormat.tv));

    final q = sent.single;
    // The kind already pins format; a second, contradicting clause would
    // return nothing at all.
    expect(q, contains('format_not_in:[NOVEL]'));
    expect(q, isNot(contains('format:TV')));
  });

  test('novels stay novels', () async {
    final c = catalogue();
    await c.searchFiltered('', ZKind.novel,
        filters: const MetaFilters(genres: ['Fantasy']));

    expect(sent.single, contains('format_in:[NOVEL]'));
    expect(sent.single, contains('genre_in:["Fantasy"]'));
  });

  test('paging asks for the page it was given', () async {
    final c = catalogue();
    await c.searchFiltered('x', ZKind.anime, page: 3);

    expect(sent.single, contains('Page(page:3'));
  });
}
