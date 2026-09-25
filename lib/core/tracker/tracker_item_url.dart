import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../zmode/zmode_ids.dart';

/// The metadata identity of a tracker stub, or null when it has none.
///
/// A tracker entry carries no provider, but it does carry the id the metadata
/// catalogue is keyed by — a MAL id from AniList/MAL, a TMDB one from Simkl,
/// or AniList's own id when there is no MAL one — which is the same identity a
/// `zm://` title uses. That lets the entry open
/// straight into Detail instead of a search for its own name.
ZCanonical? trackerCanonical(MediaItem stub) {
  final mal = stub.malId;
  if (mal != null) {
    return ZCanonical(switch (stub.type) {
      ProviderType.manga => ZKind.manga,
      ProviderType.novel => ZKind.novel,
      _ => ZKind.anime,
    }, 'mal:$mal');
  }
  final tmdb = stub.tmdbId;
  if (tmdb != null) {
    return ZCanonical(stub.tmdbIsTv ? ZKind.tv : ZKind.movie, 'tmdb:$tmdb');
  }
  // AniList's own id, for the many entries with no MAL id — the catalogue
  // already resolves `al:` (it keys its own browse rows that way when idMal is
  // null), so this is the same identity, not a new one.
  final al = stub.anilistId;
  if (al != null) {
    return ZCanonical(switch (stub.type) {
      ProviderType.manga => ZKind.manga,
      ProviderType.novel => ZKind.novel,
      _ => ZKind.anime,
    }, 'al:$al');
  }
  return null;
}

/// Recover MAL / AniList / TMDB ids from a saved title.
///
/// Cloud My List rows do not persist those fields. Z-mode titles still carry
/// them in the url (`zm://anime/mal:123`) or the item id (`mal:123`). Used
/// when adding/removing on a tracker so we never ask [SourceRepository] to
/// load the `zm` pseudo-provider.
({int? malId, int? anilistId, int? tmdbId, bool tmdbIsTv}) trackerIdsFromItem(
  MediaItem item,
) {
  var mal = item.malId;
  var al = item.anilistId;
  var tmdb = item.tmdbId;
  var isTv = item.tmdbIsTv;

  final z = item.url.isNotEmpty ? ZmodeIds.parseShow(item.url) : null;
  final raw = z?.id ?? (item.sourceId == ZmodeIds.sourceId ? item.id : null);
  if (raw != null) {
    if (raw.startsWith('mal:')) {
      mal ??= int.tryParse(raw.substring(4));
    } else if (raw.startsWith('al:')) {
      al ??= int.tryParse(raw.substring(3));
    } else if (raw.startsWith('tmdb:')) {
      tmdb ??= int.tryParse(raw.substring(5));
    }
    if (z != null) isTv = z.kind == ZKind.tv;
  }
  return (malId: mal, anilistId: al, tmdbId: tmdb, tmdbIsTv: isTv);
}

/// A tracker stub re-keyed to its metadata identity so a tap opens its Detail
/// page. Null when the stub has no id to go on — the caller falls back to a
/// search for the title ([SearchScreen] with the stub's title as the query).
MediaItem? playableTrackerItem(MediaItem stub, {String? savedFrom}) {
  final c = trackerCanonical(stub);
  if (c == null) return null;
  return MediaItem(
    id: c.id,
    title: stub.title,
    englishTitle: stub.englishTitle,
    cover: stub.cover,
    url: ZmodeIds.showUrl(c),
    type: stub.type,
    sourceId: ZmodeIds.sourceId,
    malId: stub.malId,
    anilistId: stub.anilistId,
    tmdbId: stub.tmdbId,
    tmdbIsTv: stub.tmdbIsTv,
    // Whoever surfaced the stub stays its origin after the re-key.
    savedFrom: savedFrom,
  );
}
