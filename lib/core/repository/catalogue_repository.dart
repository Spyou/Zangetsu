import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../playback/source_health_store.dart';
import '../models/video_source.dart';

/// What the catalogue screens (Home, Detail, Search) need from whatever is
/// feeding them. `SourceRepository` already satisfies this; `MetadataRepository`
/// is the other implementation. Screens hold this type and never learn which
/// one they have.
abstract interface class CatalogueRepository {
  String get sourceId;
  List<({String id, String name})> get loadedSources;
  bool hasSource(String sourceId);
  String displayName(String sourceId);
  void syncSearchCache();

  Future<List<HomeSection>> home({String category = 'sub', String? sourceId});

  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  });

  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  });

  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
  });

  Future<void> clearHttpCache();

  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  });

  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  });

  Future<({List<VideoSource> sources, bool done})> polledSources(
    String episodeUrl, {
    String? sourceId,
  });
}
