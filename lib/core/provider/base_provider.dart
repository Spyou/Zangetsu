import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';

/// Dart-side mirror of the JS provider contract. Every JS provider in
/// `providers/*.js` exports these globals:
///   - getInfo()
///   - popular(opts)
///   - search(query, page, opts)
///   - getDetail(url, opts)
///   - getEpisodes(url, opts)
///   - getVideoSources(episodeUrl)   // returns playable streams
abstract class BaseProvider {
  String get sourceId;

  /// Human-friendly label for the source picker / labelling. Falls back to
  /// [sourceId] when a provider has no nicer name.
  String get displayName;

  Future<ProviderInfo> getInfo();

  /// CloudStream-style Home rows. Returns the provider's own named sections,
  /// or `null` when the provider can't supply them (the repository then
  /// synthesizes default rows from [popular]).
  Future<List<HomeSection>?> getHome({String category = 'sub'});

  /// Returns the popular/trending feed. [category] is 'sub' or 'dub'.
  /// [dateRange] is the trending window in days; [page] for pagination.
  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  });

  /// [category] is an optional listing hint (e.g. 'sub', 'dub').
  Future<List<MediaItem>> search(
    String query,
    int page, {
    String category = '',
  });

  /// [category] is 'sub' or 'dub' — controls which episode list is fetched.
  Future<MediaDetail> getDetail(String url, {String category = 'sub'});

  /// [category] is 'sub' or 'dub'.
  Future<List<Episode>> getEpisodes(String url, {String category = 'sub'});

  /// The video leaf — returns one or more playable [VideoSource]s for an
  /// episode (the UI filters by kind/quality/lang).
  ///
  /// [fast] (playback only) asks the provider to return as soon as the first
  /// playable link(s) are ready instead of waiting for every mirror — trims the
  /// "tap → playing" delay. Downloads leave it false to get all servers.
  Future<List<VideoSource>> getVideoSources(
    String episodeUrl, {
    bool fast = false,
  });
}
