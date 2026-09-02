import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../playback/source_health_store.dart';
import '../models/video_source.dart';
import '../logging/app_logger.dart';
import '../zmode/zmode_ids.dart';
import 'catalogue_repository.dart';

/// Sits in front of both catalogues and forwards each call:
///
/// * Browsing (`home`, `search`, `loadedSources`, …) follows the **toggle** —
///   that is the whole point of Zangetsu Mode.
/// * Anything that names a title (`detail`, `episodes`, `sources`, …) follows
///   the **url**: a `zm://` url is metadata, everything else is a source. A
///   title opened from a metadata row must keep resolving through metadata
///   even if the toggle flips underneath it, and a source url can never be
///   answered by AniList.
///
/// One instance lives in the injector; toggling never re-registers anything.
class CatalogueRouter implements CatalogueRepository {
  CatalogueRouter({
    required CatalogueRepository source,
    required CatalogueRepository metadata,
    required bool Function() enabled,
  }) : _source = source,
       _meta = metadata,
       _enabled = enabled;

  final CatalogueRepository _source;
  final CatalogueRepository _meta;
  final bool Function() _enabled;

  CatalogueRepository get _browse => _enabled() ? _meta : _source;
  CatalogueRepository _forUrl(String url) =>
      ZmodeIds.isZ(url) ? _meta : _source;

  @override
  String get sourceId => _browse.sourceId;
  @override
  List<({String id, String name})> get loadedSources => _browse.loadedSources;
  @override
  bool hasSource(String sourceId) =>
      sourceId == ZmodeIds.sourceId ? _enabled() : _source.hasSource(sourceId);
  @override
  String displayName(String sourceId) => sourceId == ZmodeIds.sourceId
      ? _meta.displayName(sourceId)
      : _source.displayName(sourceId);
  @override
  void syncSearchCache() => _source.syncSearchCache();

  @override
  Future<List<HomeSection>> home({String category = 'sub', String? sourceId}) =>
      _browse.home(category: category, sourceId: sourceId);

  @override
  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) => _browse.search(query, category: category, sourceId: sourceId);

  @override
  Future<({List<MediaItem> items, SourceOutcome outcome})> searchStatus(
    String query, {
    String category = 'sub',
    String? sourceId,
    String? filtersJson,
    bool cache = false,
    int page = 1,
  }) => _browse.searchStatus(
    query,
    category: category,
    sourceId: sourceId,
    filtersJson: filtersJson,
    cache: cache,
    page: page,
  );

  @override
  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
    void Function(MediaDetail partial)? onPartial,
  }) {
    final via = ZmodeIds.isZ(url) ? 'metadata' : 'source';
    AppLogger.instance.log('[detail] route $via url=$url sourceId=$sourceId');
    return _forUrl(url).detail(
      url,
      category: category,
      sourceId: sourceId,
      onPartial: onPartial,
    );
  }

  @override
  Future<void> clearHttpCache() => _source.clearHttpCache();

  @override
  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) => _forUrl(url).episodes(url, category: category, sourceId: sourceId);

  @override
  Future<List<VideoSource>> sources(
    String episodeUrl, {
    String? sourceId,
    bool fast = false,
  }) => _forUrl(episodeUrl).sources(episodeUrl, sourceId: sourceId, fast: fast);

  @override
  Future<({List<VideoSource> sources, bool done})> polledSources(
    String episodeUrl, {
    String? sourceId,
  }) => _forUrl(episodeUrl).polledSources(episodeUrl, sourceId: sourceId);
}
