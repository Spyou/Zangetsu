import '../models/watch_status.dart';
import 'tracker.dart';

/// Fans every list/progress write out to all connected trackers at once
/// (AniList + MyAnimeList + Simkl). Each tracker self-gates (skips when
/// disconnected / auto-sync off / type not applicable), and a failure in one
/// never blocks the others.
class TrackerHub {
  TrackerHub(this.trackers);

  final List<Tracker> trackers;

  Iterable<Tracker> get connected => trackers.where((t) => t.isConnected);
  bool get anyConnected => connected.isNotEmpty;

  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
  }) => _fan(
    (t) => t.markWatching(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
    ),
  );

  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    required int episode,
  }) => _fan(
    (t) => t.scrobble(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      episode: episode,
    ),
  );

  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    required WatchStatus status,
  }) => _fan(
    (t) => t.setStatus(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      status: status,
    ),
  );

  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
  }) => _fan(
    (t) => t.removeFromList(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
    ),
  );

  Future<void> _fan(Future<void> Function(Tracker) op) async {
    await Future.wait(
      connected.map((t) async {
        try {
          await op(t);
        } catch (_) {/* one tracker failing must not block the rest */}
      }),
    );
  }
}
