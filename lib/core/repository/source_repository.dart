import '../models/episode.dart';
import '../models/home_section.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/video_source.dart';
import '../provider/base_provider.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/provider_manager.dart';
import '../state/active_source_cubit.dart';

/// Facade over the active provider runtime for the UI layer.
/// The active source is driven by [activeSource] so callers can switch at
/// runtime without recreating the repository.
class SourceRepository {
  SourceRepository({
    required ProviderManager manager,
    required CloudStreamManager csManager,
    required ActiveSourceCubit activeSource,
  }) : _manager = manager,
       _csManager = csManager,
       _active = activeSource;

  final ProviderManager _manager;
  final CloudStreamManager _csManager;
  final ActiveSourceCubit _active;

  /// True for CloudStream source ids (`cs:<name>`), which route to the native
  /// plugin host instead of the JS runtime.
  static bool _isCloudStream(String id) => id.startsWith('cs:');

  /// The currently-active source identifier.
  String get sourceId => _active.state;

  /// All currently-loaded sources (id + display name), for cross-source search
  /// and source labelling. JS providers first (registry order), then any
  /// installed CloudStream sources.
  List<({String id, String name})> get loadedSources => [
    ..._manager.all.map((p) => (id: p.sourceId, name: p.displayName)),
    ..._csManager.all.map((p) => (id: p.sourceId, name: p.displayName)),
  ];

  /// Human-friendly name for a source id (falls back to the id itself).
  String displayName(String sourceId) {
    if (_isCloudStream(sourceId)) {
      return _csManager.get(sourceId)?.displayName ?? sourceId;
    }
    return _manager.get(sourceId)?.displayName ?? sourceId;
  }

  /// Resolves the provider for a per-call [id], falling back to the active
  /// source when [id] is null. Lets cross-source items (Continue Watching,
  /// My List, etc.) route to their OWN provider instead of the active one.
  /// CloudStream ids (`cs:<name>`) route to the native plugin host.
  BaseProvider _providerFor(String? id) {
    final resolved = id ?? _active.state;
    final p = _isCloudStream(resolved)
        ? _csManager.get(resolved)
        : _manager.get(resolved);
    if (p == null) {
      throw StateError('Provider not loaded: $resolved');
    }
    return p;
  }

  Future<List<MediaItem>> popular({
    String category = 'sub',
    int dateRange = 7,
    int page = 1,
    String? sourceId,
  }) => _providerFor(
    sourceId,
  ).popular(category: category, dateRange: dateRange, page: page);

  /// CloudStream-style Home: the active provider's own named rows. When the
  /// provider defines `getHome` we render exactly what it returns (empty rows
  /// dropped). When it doesn't, we synthesize the legacy three rows from
  /// [popular] so older providers keep working. Each underlying fetch is
  /// fail-safe — one broken row never kills the others.
  Future<List<HomeSection>> home({
    String category = 'sub',
    String? sourceId,
  }) async {
    final provider = _providerFor(sourceId);

    final sections = await provider.getHome(category: category);
    if (sections != null) {
      return sections.where((s) => s.items.isNotEmpty).toList();
    }

    // Fallback for providers without getHome.
    final results = await Future.wait([
      provider
          .popular(category: category, dateRange: 1)
          .catchError((_) => <MediaItem>[]),
      provider
          .popular(category: category, dateRange: 30)
          .catchError((_) => <MediaItem>[]),
      provider
          .popular(category: category, dateRange: 0)
          .catchError((_) => <MediaItem>[]),
    ]);
    final fallback = <HomeSection>[
      HomeSection(title: 'Trending Now', items: results[0]),
      HomeSection(title: 'Popular This Month', items: results[1]),
      HomeSection(title: 'All-Time Favorites', items: results[2]),
    ];
    return fallback.where((s) => s.items.isNotEmpty).toList();
  }

  Future<List<MediaItem>> search(
    String query, {
    String category = 'sub',
    String? sourceId,
  }) => _providerFor(sourceId).search(query, 1, category: category);

  Future<MediaDetail> detail(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) => _providerFor(sourceId).getDetail(url, category: category);

  Future<List<Episode>> episodes(
    String url, {
    String category = 'sub',
    String? sourceId,
  }) => _providerFor(sourceId).getEpisodes(url, category: category);

  Future<List<VideoSource>> sources(String episodeUrl, {String? sourceId}) =>
      _providerFor(sourceId).getVideoSources(episodeUrl);
}
