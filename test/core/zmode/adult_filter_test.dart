// Adult content is a privacy setting, so the interesting cases are the ones
// where it must NOT leak: filters are persisted, and a saved "adult" choice has to
// stop working the moment the switch goes off.

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

  test('adult titles are excluded by default', () async {
    final c = catalogue();
    await c.searchFiltered('naruto', ZKind.anime);

    expect(sent.single, contains('isAdult:false'));
  });

  test('excluded even with other filters set', () async {
    final c = catalogue();
    await c.searchFiltered('', ZKind.anime,
        filters: const MetaFilters(genres: ['Action']));

    expect(sent.single, contains('isAdult:false'));
  });

  test('adult on drops the clause rather than inverting it', () async {
    final c = catalogue();
    await c.searchFiltered('', ZKind.anime,
        filters: const MetaFilters(adult: true));

    // isAdult:true would return ONLY adult titles, which is not what "show
    // adult content" means — it means stop hiding them.
    expect(sent.single, isNot(contains('isAdult')));
  });

  test('adult counts as a filter, so an untouched sheet stays empty', () {
    expect(const MetaFilters().isEmpty, isTrue);
    expect(const MetaFilters(adult: true).isEmpty, isFalse);
  });

  test('the flag survives the round trip', () {
    const f = MetaFilters(adult: true, genres: ['Action']);
    expect(MetaFilters.fromJson(f.toJson())!.adult, isTrue);
    // And the default decodes as off rather than as missing.
    expect(MetaFilters.fromJson(const MetaFilters().toJson())!.adult, isFalse);
  });
}
