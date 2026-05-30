import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/video_source.dart';
import '../provider/provider_manager.dart';

/// Facade over the active provider runtime for the UI layer. For 2B it targets
/// the bundled AllAnime provider; later phases let the user pick the source.
class SourceRepository {
  SourceRepository({required ProviderManager manager, this.sourceId = 'allanime'})
      : _manager = manager;

  final ProviderManager _manager;
  final String sourceId;

  JsProvider get _p {
    final p = _manager.get(sourceId);
    if (p == null) throw StateError('Provider not loaded: $sourceId');
    return p;
  }

  Future<List<MediaItem>> search(String query, {String category = 'sub'}) =>
      _p.search(query, 1, category: category);

  Future<MediaDetail> detail(String url) => _p.getDetail(url);

  Future<List<Episode>> episodes(String url) => _p.getEpisodes(url);

  Future<List<VideoSource>> sources(String episodeUrl) =>
      _p.getVideoSources(episodeUrl);
}
