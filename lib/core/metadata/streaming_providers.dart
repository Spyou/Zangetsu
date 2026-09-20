import '../zmode/tmdb_catalogue.dart' show TmdbGet;
import 'streaming_service.dart';

/// The streaming services TMDB lists for a country.
///
/// Merged from the `/movie` and `/tv` endpoints because a service usually
/// appears in both and the browse screen shows one tile per service, not two.
///
/// Cached in memory for the session rather than on disk: the list is small, one
/// call, and it only changes when the region does — which the user does by
/// hand. No Hive box, so nothing to add to the backup drift guard.
class StreamingProvidersService {
  StreamingProvidersService(this._get);

  final TmdbGet _get;
  final Map<String, List<StreamingService>> _cache = {};

  /// Services available in [region] (an ISO 3166-1 alpha-2 code, e.g. `IN`), in
  /// TMDB's own display order. Empty on any failure — this drives a browse
  /// screen, and an empty grid with its own empty state beats an exception.
  Future<List<StreamingService>> list(String region) async {
    final hit = _cache[region];
    if (hit != null) return hit;
    try {
      final params = {'watch_region': region};
      final responses = await Future.wait([
        _get('/watch/providers/tv', params),
        _get('/watch/providers/movie', params),
      ]);
      final byId = <int, StreamingService>{};
      for (final data in responses) {
        final results = data?['results'];
        if (results is! List) continue;
        for (final r in results) {
          if (r is! Map) continue;
          final s = StreamingService.fromJson(Map<String, dynamic>.from(r));
          if (s == null || !isSubscribableService(s.id, s.name)) continue;
          // First endpoint wins; the rows are identical where they overlap.
          byId.putIfAbsent(s.id, () => s);
        }
      }
      // Majors first (see [kPopularProviderIds]), then TMDB's own regional
      // order. The rail shows only the first handful, so this is the
      // difference between seeing Netflix and seeing a documentary catalogue
      // nobody subscribes to.
      int rank(StreamingService s) {
        final i = kPopularProviderIds.indexOf(s.id);
        return i < 0 ? kPopularProviderIds.length : i;
      }

      final out = byId.values.toList()
        ..sort((a, b) {
          final r = rank(a).compareTo(rank(b));
          if (r != 0) return r;
          final p = a.priority.compareTo(b.priority);
          return p != 0 ? p : a.name.compareTo(b.name);
        });
      // Only a real answer is cached — a transient failure must not pin an
      // empty grid for the rest of the session.
      if (out.isNotEmpty) _cache[region] = out;
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Drop the cache — called when the region changes.
  void clearCache() => _cache.clear();
}
