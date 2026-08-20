import '../di/injector.dart';
import '../mode/content_mode.dart';
import '../models/watch_status.dart';
import '../playback/playback_prefs.dart';
import '../privacy/incognito_mode.dart';
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

  /// Trackers that can actually sync in [mode]. In a reading mode this drops
  /// video-only trackers (Simkl), which would otherwise be offered as an
  /// account that can never sync a single title there. Anime mode returns
  /// every tracker, so today's behaviour is unchanged.
  ///
  /// Display/selection only — the write paths already self-gate per
  /// [MediaKind], so this never changes what gets synced.
  Iterable<Tracker> forMode(ContentMode mode) =>
      mode.isReading ? trackers.where((t) => t.supportsReading) : trackers;

  /// [forMode], narrowed to the ones the user has actually connected.
  Iterable<Tracker> connectedForMode(ContentMode mode) =>
      forMode(mode).where((t) => t.isConnected);

  /// Whether the "as you watch" writes are allowed through. Reads defensively
  /// so a context without [PlaybackPrefs] registered (tests, early startup)
  /// behaves as it always did rather than silently going quiet.
  static bool get _autoTrackOn =>
      !sl.isRegistered<PlaybackPrefs>() || sl<PlaybackPrefs>().autoTrack;

  Future<void> markWatching({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) async {
    // Only ever called on playback start, so there's no manual path to spare.
    if (!_autoTrackOn) return;
    if (IncognitoMode.on) return; // incognito: pause auto-tracking
    await _fan(
      (t) => t.markWatching(
        malId: malId,
        title: title,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        imdbId: imdbId,
        kind: kind,
      ),
    );
  }

  Future<void> scrobble({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required int episode,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
    bool auto = true,
  }) async {
    // [auto] false = the user asked for this one by hand ("Mark as watched"),
    // so the auto-track preference doesn't apply. Incognito still does.
    if (auto && !_autoTrackOn) return;
    if (IncognitoMode.on) return; // incognito: pause auto-scrobble
    await _fan(
      (t) => t.scrobble(
        malId: malId,
        title: title,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        imdbId: imdbId,
        episode: episode,
        kind: kind,
        novel: novel,
      ),
    );
  }

  Future<void> setStatus({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    required WatchStatus status,
    MediaKind kind = MediaKind.anime,
  }) => _fan(
    (t) => t.setStatus(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      status: status,
      kind: kind,
    ),
  );

  Future<void> removeFromList({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    MediaKind kind = MediaKind.anime,
  }) => _fan(
    (t) => t.removeFromList(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      kind: kind,
    ),
  );

  /// Read the user's entry for one title. Queries every connected tracker in
  /// parallel and returns the FIRST that has the title on the user's list —
  /// that becomes the sheet's editable state. Falls back
  /// to the first that returned any data (so total-episodes / next-airing still
  /// show even when the title isn't on a list yet). Null when nothing matched.
  /// [pinnedIds] maps a tracker's [Tracker.displayName] to a chosen native id.
  Future<TrackerEntry?> fetchEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    Map<String, String>? pinnedIds,
    MediaKind kind = MediaKind.anime,
    bool novel = false,
  }) async {
    final results = await Future.wait(
      connected.map((t) async {
        try {
          return await t.fetchEntry(
            malId: malId,
            title: title,
            tmdbId: tmdbId,
            tmdbIsTv: tmdbIsTv,
            imdbId: imdbId,
            pinnedId: pinnedIds?[t.displayName],
            kind: kind,
            novel: novel,
          );
        } catch (_) {
          return null;
        }
      }),
    );
    for (final r in results) {
      if (r != null && r.onList) return r;
    }
    return results.firstWhere((r) => r != null, orElse: () => null);
  }

  /// Write status/score/progress for one title to EVERY connected tracker at
  /// once (the sheet's Apply). Not gated by incognito — this is an explicit,
  /// deliberate edit, not passive auto-tracking.
  Future<void> updateEntry({
    int? malId,
    String? title,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
    Map<String, String>? pinnedIds,
    WatchStatus? status,
    double? score,
    int? progress,
    MediaKind kind = MediaKind.anime,
  }) => _fan(
    (t) => t.updateEntry(
      malId: malId,
      title: title,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      pinnedId: pinnedIds?[t.displayName],
      status: status,
      score: score,
      progress: progress,
      kind: kind,
    ),
  );

  /// Candidate matches from every connected tracker (the match-fixer), in
  /// connection order.
  Future<List<TrackerSearchResult>> searchEntries(
    String query, {
    MediaKind kind = MediaKind.anime,
  }) async {
    final lists = await Future.wait(
      connected.map((t) async {
        try {
          return await t.searchEntries(query, kind: kind);
        } catch (_) {
          return const <TrackerSearchResult>[];
        }
      }),
    );
    return [for (final l in lists) ...l];
  }

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
