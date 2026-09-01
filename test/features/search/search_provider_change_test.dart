// Switching metadata provider has to clear search results. The Z Mode source
// id is 'zm' whichever of AniList/MAL/TMDB/Simkl answered, so nothing about a
// stale result looks stale — it carries the same source id the new provider
// would use.

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'dart:io';
import 'package:watch_app/core/zmode/metadata_provider_prefs.dart';

void main() {
  late Directory dir;
  late MetadataProviderPrefs prefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('provrev');
    Hive.init(dir.path);
    prefs = await MetadataProviderPrefs.open();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('changing the anime provider bumps the revision', () async {
    final before = MetadataProviderPrefs.revision.value;

    await prefs.setAnime(AnimeProvider.mal);

    expect(MetadataProviderPrefs.revision.value, greaterThan(before),
        reason: 'the search bloc and Home both reload off this');
  });

  test('re-picking the same provider does not', () async {
    await prefs.setAnime(AnimeProvider.mal);
    final after = MetadataProviderPrefs.revision.value;

    await prefs.setAnime(AnimeProvider.mal);

    // Otherwise opening the picker and confirming the current choice would
    // throw away results for no reason.
    expect(MetadataProviderPrefs.revision.value, after);
  });

  test('the video provider bumps it too', () async {
    final before = MetadataProviderPrefs.revision.value;

    await prefs.setVideo(VideoProvider.simkl);

    expect(MetadataProviderPrefs.revision.value, greaterThan(before));
  });
}
