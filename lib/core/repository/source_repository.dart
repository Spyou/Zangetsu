import 'package:flutter/foundation.dart';

import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/video_source.dart';
import '../provider/provider_manager.dart';

/// Facade over the active provider runtime for the UI layer.
/// The active source is driven by [activeSource] so callers can switch at
/// runtime without recreating the repository.
class SourceRepository {
  SourceRepository({
    required ProviderManager manager,
    required ValueNotifier<String> activeSource,
  })  : _manager = manager,
        _active = activeSource;

  final ProviderManager _manager;
  final ValueNotifier<String> _active;

  /// The currently-active source identifier.
  String get sourceId => _active.value;

  JsProvider get _p {
    final p = _manager.get(_active.value);
    if (p == null) throw StateError('Provider not loaded: ${_active.value}');
    return p;
  }

  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
  }) =>
      _p.popular(category: category, dateRange: dateRange, page: page);

  Future<List<MediaItem>> search(String query, {String category = 'sub'}) =>
      _p.search(query, 1, category: category);

  Future<MediaDetail> detail(String url, {String category = 'sub'}) =>
      _p.getDetail(url, category: category);

  Future<List<Episode>> episodes(String url, {String category = 'sub'}) =>
      _p.getEpisodes(url, category: category);

  Future<List<VideoSource>> sources(String episodeUrl) =>
      _p.getVideoSources(episodeUrl);
}
