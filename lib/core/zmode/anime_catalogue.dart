import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import 'metadata_filters.dart';
import 'zmode_ids.dart';

/// What an anime/manga metadata provider has to answer, so AniList and MAL are
/// interchangeable behind [MetadataRepository].
///
/// Both already had these four methods with identical signatures; this only
/// names the contract so one can stand in for the other when the chosen
/// provider is unreachable.
abstract interface class AnimeCatalogue {
  Future<List<HomeSection>> home(ZKind kind);

  /// One home row's next page, so "See all" can keep scrolling.
  ///
  /// [rowId] is whatever the provider put in its row's
  /// [HomeSection.more.categoryId] — a query fragment for one provider, an
  /// endpoint for another. Page numbers are 1-based and page 1 is what [home]
  /// already returned. An empty list means the end (or that the row cannot
  /// page), which is how the browse grid stops asking.
  Future<List<MediaItem>> browseRow(ZKind kind, String rowId, int page);
  Future<List<MediaItem>> search(String q, ZKind kind);

  /// Search and/or browse with [filters] applied by the SERVER.
  ///
  /// An empty [q] plus filters is a browse. A provider that cannot filter
  /// server-side must ignore [filters] and return a plain search — MAL accepts
  /// filter parameters and silently returns unfiltered results, so the UI is
  /// responsible for not offering filters there. [page] is 1-based.
  Future<List<MediaItem>> searchFiltered(
    String q,
    ZKind kind, {
    MetaFilters? filters,
    int page,
  });

  /// Whether [searchFiltered] actually honours its filters.
  bool get supportsFilters;
  Future<MediaDetail> detail(ZCanonical c);
  Future<List<Episode>> episodes(ZCanonical c);
}
