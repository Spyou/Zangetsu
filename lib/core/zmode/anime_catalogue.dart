import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import 'zmode_ids.dart';

/// What an anime/manga metadata provider has to answer, so AniList and MAL are
/// interchangeable behind [MetadataRepository].
///
/// Both already had these four methods with identical signatures; this only
/// names the contract so one can stand in for the other when the chosen
/// provider is unreachable.
abstract interface class AnimeCatalogue {
  Future<List<HomeSection>> home(ZKind kind);
  Future<List<MediaItem>> search(String q, ZKind kind);
  Future<MediaDetail> detail(ZCanonical c);
  Future<List<Episode>> episodes(ZCanonical c);
}
