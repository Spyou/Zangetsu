import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/models/watch_status.dart';
import 'package:watch_app/core/tracker/tracker.dart';

/// Simkl has no single-item status read, so fetchEntry filters the library.
/// It used to match only on MAL id, so a film or series — which carries none —
/// fell straight through: Apply wrote to Simkl, the Tracking button had
/// nothing to re-read, and its icon never changed. Reported on "Colony"
/// (tmdb 1375646), where the sync really had worked.
///
/// These pin the matching rule itself, which is where the danger is: a TMDB id
/// means one thing for a film and another for a series.
bool matches({
  required TrackerListItem it,
  int? malId,
  int? tmdbId,
  bool tmdbIsTv = false,
  int? pinned,
}) {
  final matchesMal = malId != null && it.item.malId == malId;
  final matchesPinned = pinned != null && it.item.id == 'tracker:simkl:$pinned';
  final matchesTmdb =
      tmdbId != null && it.item.tmdbId == tmdbId && it.tmdbIsTv == tmdbIsTv;
  return matchesMal || matchesPinned || matchesTmdb;
}

TrackerListItem entry({
  int? malId,
  int? tmdbId,
  bool isTv = false,
  String id = 'tracker:simkl:1',
}) => TrackerListItem(
  item: MediaItem(
    id: id,
    title: 'x',
    url: 'u',
    sourceId: 's',
    type: ProviderType.movie,
    malId: malId,
    tmdbId: tmdbId,
  ),
  status: WatchStatus.watching,
  tmdbIsTv: isTv,
);

void main() {
  test('a film is found by its TMDB id — the Colony case', () {
    expect(
      matches(it: entry(tmdbId: 1375646), tmdbId: 1375646),
      isTrue,
    );
  });

  test('a film does NOT match a series with the same TMDB number', () {
    // The whole reason the kind is part of the comparison.
    expect(
      matches(it: entry(tmdbId: 1375646, isTv: true), tmdbId: 1375646),
      isFalse,
    );
    expect(
      matches(it: entry(tmdbId: 1375646), tmdbId: 1375646, tmdbIsTv: true),
      isFalse,
    );
  });

  test('anime still matches by MAL id — unchanged', () {
    expect(matches(it: entry(malId: 21), malId: 21), isTrue);
    expect(matches(it: entry(malId: 21), malId: 99), isFalse);
  });

  test('a pinned Simkl id still wins on its own', () {
    expect(matches(it: entry(id: 'tracker:simkl:777'), pinned: 777), isTrue);
  });
}
