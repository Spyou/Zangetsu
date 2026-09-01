import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import 'zmode_ids.dart';

/// What a movie/TV metadata provider has to answer, so TMDB and Simkl are
/// interchangeable behind [MetadataRepository]. The anime twin is
/// [AnimeCatalogue]; both exist so one provider can stand in for the other.
///
/// Note there is no `episodes` here: for movies and series the episode list
/// comes from the matched source, never from metadata.
abstract interface class VideoCatalogue {
  Future<List<HomeSection>> home();
  Future<List<MediaItem>> search(String q);
  Future<MediaDetail> detail(ZCanonical c);
}
