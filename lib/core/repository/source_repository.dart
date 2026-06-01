import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/video_source.dart';
import '../provider/provider_manager.dart';
import '../state/active_source_cubit.dart';

/// Facade over the active provider runtime for the UI layer.
/// The active source is driven by [activeSource] so callers can switch at
/// runtime without recreating the repository.
class SourceRepository {
  SourceRepository({
    required ProviderManager manager,
    required ActiveSourceCubit activeSource,
  }) : _manager = manager,
       _active = activeSource;

  final ProviderManager _manager;
  final ActiveSourceCubit _active;

  /// The currently-active source identifier.
  String get sourceId => _active.state;

  /// Resolves the provider for a per-call [id], falling back to the active
  /// source when [id] is null. Lets cross-source items (Continue Watching,
  /// My List, etc.) route to their OWN provider instead of the active one.
  JsProvider _providerFor(String? id) {
    final p = _manager.get(id ?? _active.state);
    if (p == null) throw StateError('Provider not loaded: ${id ?? _active.state}');
    return p;
  }

  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
    String? sourceId,
  }) => _providerFor(sourceId)
      .popular(category: category, dateRange: dateRange, page: page);

  Future<List<MediaItem>> search(String query,
          {String category = 'sub', String? sourceId}) =>
      _providerFor(sourceId).search(query, 1, category: category);

  Future<MediaDetail> detail(String url,
          {String category = 'sub', String? sourceId}) =>
      _providerFor(sourceId).getDetail(url, category: category);

  Future<List<Episode>> episodes(String url,
          {String category = 'sub', String? sourceId}) =>
      _providerFor(sourceId).getEpisodes(url, category: category);

  Future<List<VideoSource>> sources(String episodeUrl, {String? sourceId}) =>
      _providerFor(sourceId).getVideoSources(episodeUrl);
}
