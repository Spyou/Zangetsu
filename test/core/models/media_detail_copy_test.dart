// copyWith is hand-written, and the detail screen's whole metadata section
// travels through it: the catalogue builds the record, then the repository
// copies it to swap in the matched source's episodes. A field missing from
// copyWith is therefore invisible on the page no matter how correctly it was
// fetched — which is exactly what happened when score/format/tags and the
// rest were added. This walks props instead of naming fields, so the next one
// added is covered without anybody remembering to come back here.

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/episode.dart';
import 'package:watch_app/core/models/media_detail.dart';
import 'package:watch_app/core/models/provider_info.dart';

void main() {
  final full = MediaDetail(
    id: 'mal:5114',
    title: 'A',
    url: 'zm://a',
    type: ProviderType.anime,
    sourceId: 'zm',
    score: 87,
    format: 'TV',
    durationMins: 24,
    airingAt: DateTime(2026, 1, 2),
    nextEpisode: 1177,
    tags: const [MediaTag(name: 'Pirates', rank: 98)],
    startDate: DateTime(1999, 10, 20),
    endDate: DateTime(2010, 7, 4),
    sourceMaterial: 'Manga',
    country: 'JP',
    popularity: 746932,
    nativeTitle: 'ONE PIECE',
    synonyms: const ['OP'],
    isAdult: true,
  );

  test('an untouched copy is the same record', () {
    expect(full.copyWith(), full);
  });

  test('swapping episodes keeps every other field', () {
    // What MetadataRepository does: the catalogue's record, the source's
    // chapters. It used to rebuild by hand here and lose the rest.
    final copied = full.copyWith(
      id: 'src-1',
      sourceId: 'mihon:x',
      episodes: const [Episode(id: '1', title: 'Ch 1', url: 'u')],
    );

    expect(copied.episodes, hasLength(1));
    expect(copied.sourceId, 'mihon:x');
    // Everything the copy did NOT set must survive it.
    expect(copied.score, full.score);
    expect(copied.format, full.format);
    expect(copied.durationMins, full.durationMins);
    expect(copied.airingAt, full.airingAt);
    expect(copied.nextEpisode, full.nextEpisode);
    expect(copied.tags, full.tags);
    expect(copied.startDate, full.startDate);
    expect(copied.endDate, full.endDate);
    expect(copied.sourceMaterial, full.sourceMaterial);
    expect(copied.country, full.country);
    expect(copied.popularity, full.popularity);
    expect(copied.nativeTitle, full.nativeTitle);
    expect(copied.synonyms, full.synonyms);
    expect(copied.isAdult, full.isAdult);
  });

  test('every field props compares is carried by copyWith', () {
    // props is the model's own list of what it is made of. A field present
    // there but absent from copyWith reverts to its default on any copy, so
    // the two lists disagreeing IS the bug.
    final empty = MediaDetail(
      id: full.id,
      title: full.title,
      url: full.url,
      type: full.type,
      sourceId: full.sourceId,
    );
    final carried = full.copyWith();

    for (var i = 0; i < full.props.length; i++) {
      // Only fields that actually differ from the default prove anything.
      if (full.props[i] == empty.props[i]) continue;
      expect(
        carried.props[i],
        full.props[i],
        reason: 'props[$i] is dropped by copyWith — add it there',
      );
    }
  });
}
