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
  /// [abandoned] lets a caller say the answer is no longer wanted — the
  /// screen was closed before the fetch came back.
  ///
  /// Provider work runs strictly one call at a time (see `_serialized` in
  /// provider_manager.dart), and a fetch nobody is waiting for still holds
  /// that queue. Opening three titles five seconds apart made them take 12s,
  /// 24s and 27s in a shared report — each waiting out the ones already backed
  /// out of. Asked when a queued call is about to start, so leaving stops the
  /// pile-up; a call already running cannot be recalled.
  ///
  /// Optional and null by default: every existing caller keeps exactly the
  /// behaviour it has, and only a screen that knows when it is gone opts in.
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
    bool Function()? abandoned,
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
