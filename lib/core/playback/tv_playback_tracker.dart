import '../di/injector.dart';
import '../models/episode.dart';
import '../tracker/tracker_hub.dart';
import 'tv_playback_helpers.dart';

/// Session-scoped AniList/MAL/Simkl auto-tracking for TV players.
///
/// Shared by native Android/Apple TV bridges and the Flutter Exo fallback so
/// tracker writes stay consistent with [PlayerController].
class TvPlaybackTracker {
  TvPlaybackTracker({
    this.malId,
    this.scrobbleTitle,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.imdbId,
    TrackerHub? hub,
  }) : _hub = hub;

  final int? malId;
  final String? scrobbleTitle;
  final int? tmdbId;
  final bool tmdbIsTv;
  final String? imdbId;

  final TrackerHub? _hub;
  final _scrobbled = <int>{};
  bool _markedWatching = false;

  bool get hasTitleId =>
      malId != null ||
      (scrobbleTitle != null && scrobbleTitle!.isNotEmpty) ||
      tmdbId != null ||
      (imdbId != null && imdbId!.isNotEmpty);

  TrackerHub? get _tracker =>
      _hub ?? (sl.isRegistered<TrackerHub>() ? sl<TrackerHub>() : null);

  void reset() {
    _scrobbled.clear();
    _markedWatching = false;
  }

  void maybeMarkWatching() {
    if (_markedWatching || !hasTitleId) return;
    final hub = _tracker;
    if (hub == null) return;
    _markedWatching = true;
    hub.markWatching(
      malId: malId,
      title: scrobbleTitle,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
    );
  }

  /// Push episode progress to connected trackers when [positionMs] crosses
  /// 92% or when [force] is true (natural completion / HLS with no duration).
  void maybeScrobble({
    required int index,
    required Episode episode,
    required int positionMs,
    required int durationMs,
    bool force = false,
  }) {
    if (!hasTitleId) return;
    maybeMarkWatching();
    final fire = force
        ? !_scrobbled.contains(index)
        : shouldScrobble(
            positionMs: positionMs,
            durationMs: durationMs,
            alreadyScrobbled: _scrobbled.contains(index),
          );
    if (!fire) return;
    final epNum = episode.number ?? (index + 1);
    if (epNum <= 0 || epNum != epNum.truncateToDouble()) return;
    final hub = _tracker;
    if (hub == null) return;
    _scrobbled.add(index);
    hub.scrobble(
      malId: malId,
      title: scrobbleTitle,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      episode: epNum.toInt(),
    );
  }
}
