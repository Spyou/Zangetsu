import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/media_item.dart';
import 'package:watch_app/core/models/provider_info.dart';
import 'package:watch_app/core/tracker/tracker_item_url.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

// A tracker entry opens Detail only if it can be re-keyed to a metadata
// identity. Entries with no MAL id used to have none, so a tap fell back to
// searching for the title — AniList carries plenty of those (Korean and
// Chinese titles especially).

MediaItem _stub({
  int? malId,
  int? anilistId,
  int? tmdbId,
  bool tmdbIsTv = false,
  ProviderType type = ProviderType.anime,
}) => MediaItem(
  id: 'tracker:anilist:x',
  title: 'Whatever',
  url: '',
  type: type,
  sourceId: '',
  malId: malId,
  anilistId: anilistId,
  tmdbId: tmdbId,
  tmdbIsTv: tmdbIsTv,
);

void main() {
  test('a MAL id wins — it is what most of the catalogue is keyed by', () {
    final c = trackerCanonical(_stub(malId: 21, anilistId: 999))!;
    expect(c.id, 'mal:21');
    expect(c.kind, ZKind.anime);
  });

  test('no MAL id falls back to AniList own id, not to nothing', () {
    final c = trackerCanonical(_stub(anilistId: 12345))!;
    expect(c.id, 'al:12345');
    expect(c.kind, ZKind.anime);
  });

  test('the AniList fallback keeps the reading kinds apart', () {
    expect(
      trackerCanonical(_stub(anilistId: 7, type: ProviderType.manga))!.kind,
      ZKind.manga,
    );
    expect(
      trackerCanonical(_stub(anilistId: 7, type: ProviderType.novel))!.kind,
      ZKind.novel,
    );
  });

  test('TMDB still wins over an AniList id for video entries', () {
    final c = trackerCanonical(
      _stub(tmdbId: 42, tmdbIsTv: true, type: ProviderType.movie),
    )!;
    expect(c.id, 'tmdb:42');
    expect(c.kind, ZKind.tv);
  });

  test('no id at all is still null, so the search fallback survives', () {
    expect(trackerCanonical(_stub()), isNull);
  });

  test('the re-keyed item carries the AniList id onward', () {
    // The Detail page re-resolves from it; dropping it here would send the
    // next lookup back to square one.
    final item = playableTrackerItem(_stub(anilistId: 12345))!;
    expect(item.anilistId, 12345);
    expect(item.sourceId, ZmodeIds.sourceId);
  });
}
