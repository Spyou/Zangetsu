import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/metadata_filters.dart';
import 'package:watch_app/core/zmode/tmdb_catalogue.dart';

// A filters-only browse — sort by Popular and nothing else — used to be sent
// to /search/multi with an empty query string, which TMDB answers with
// nothing. `MetaFilters.narrowsCatalogue` counts sort-by-Popular as no filter
// at all, so the "does this narrow anything?" test sent it down the search
// path. No query means browse, and browsing is /discover's job.

void main() {
  late List<String> paths;
  late List<Map<String, dynamic>> sent;

  TmdbCatalogue catalogue() => TmdbCatalogue((path, params) async {
    paths.add(path);
    sent.add(Map<String, dynamic>.from(params));
    return <String, dynamic>{'results': const []};
  });

  setUp(() {
    paths = [];
    sent = [];
  });

  test('no query and no narrowing filters browses discover', () async {
    await catalogue().searchFiltered('', filters: const MetaFilters());
    expect(paths.single, '/discover/movie');
    expect(sent.single['sort_by'], 'popularity.desc');
  });

  test('no query and no filters at all still browses', () async {
    await catalogue().searchFiltered('');
    expect(paths.single, startsWith('/discover/'));
  });

  test('a real query still goes to search', () async {
    await catalogue().searchFiltered('bleach', filters: const MetaFilters());
    expect(paths.single, '/search/multi');
    expect(sent.single['query'], 'bleach');
  });

  test('a query with narrowing filters still discovers, then narrows', () async {
    // Unchanged behaviour: /search/multi cannot express a genre, so the query
    // is applied to the discover results afterwards.
    await catalogue().searchFiltered(
      'bleach',
      filters: const MetaFilters(genres: ['Action']),
    );
    expect(paths.single, startsWith('/discover/'));
  });

  test('sort choices reach discover', () async {
    await catalogue().searchFiltered(
      '',
      filters: const MetaFilters(sort: MetaSort.score),
    );
    expect(sent.single['sort_by'], 'vote_average.desc');
    // A vote floor comes with it — one 10/10 vote is not a top-rated title.
    expect(sent.single['vote_count.gte'], 200);
  });
}
