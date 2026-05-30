import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';

/// Dart-side mirror of the JS provider contract. Every JS provider in
/// `providers/*.js` exports these globals:
///   - getInfo()
///   - search(query, page, opts)
///   - getDetail(url)
///   - getEpisodes(url)
///   - getVideoSources(episodeUrl)   // returns playable streams
abstract class BaseProvider {
  String get sourceId;

  Future<ProviderInfo> getInfo();

  /// `category` is an optional listing hint (e.g. 'popular', 'latest').
  Future<List<MediaItem>> search(String query, int page, {String category = ''});

  Future<MediaDetail> getDetail(String url);

  Future<List<Episode>> getEpisodes(String url);

  /// The video leaf — returns one or more playable [VideoSource]s for an
  /// episode (the UI filters by kind/quality/lang).
  Future<List<VideoSource>> getVideoSources(String episodeUrl);
}
