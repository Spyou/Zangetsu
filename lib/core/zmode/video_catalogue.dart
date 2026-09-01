import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import 'metadata_filters.dart';
import 'zmode_ids.dart';

/// What a movie/TV metadata provider has to answer, so TMDB and Simkl are
/// interchangeable behind [MetadataRepository]. The anime twin is
/// [AnimeCatalogue]; both exist so one provider can stand in for the other.
///
/// Note there is no `episodes` here: for movies and series the episode list
/// comes from the matched source, never from metadata.
abstract interface class VideoCatalogue {
  Future<List<HomeSection>> home();

  /// One home row's next page — the movie/TV twin of
  /// [AnimeCatalogue.browseRow]. Same contract: 1-based, page 1 is [home]'s
  /// output, empty means stop.
  Future<List<MediaItem>> browseRow(String rowId, int page);
  Future<List<MediaItem>> search(String q);

  /// Movie/TV twin of [AnimeCatalogue.searchFiltered]. Simkl ignores filter
  /// parameters the same way MAL does, so the same rule applies: only offer
  /// filters when [supportsFilters] is true.
  Future<List<MediaItem>> searchFiltered(
    String q, {
    MetaFilters? filters,
    int page,
  });

  /// Whether [searchFiltered] actually honours its filters.
  bool get supportsFilters;
  Future<MediaDetail> detail(ZCanonical c);
}
