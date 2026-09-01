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

  /// [onPartial], when supplied, may be called ONCE with a usable but
  /// incomplete detail before the returned future completes: the metadata is
  /// in, the episode list is not. Only [MetadataRepository] uses it — pairing
  /// a metadata title with a source means searching each installed source in
  /// turn, which is what makes that call slow, and none of the title, art or
  /// synopsis has to wait for it. A source repository already holds
  /// everything and never calls it, so a caller that just wants the finished
  /// detail simply omits it.
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
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
