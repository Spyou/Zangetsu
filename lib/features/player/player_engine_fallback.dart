import '../../core/models/video_source.dart';
import '../../core/torrent/torrent_util.dart';

enum PlaybackEngine { mpv, nativePlayer }

/// True when [source] is a torrent ExoPlayer can't open (magnet link or
/// torrent container) — the native flow must yield to mpv instead of failing
/// on it. Shared by the fallback and the launch pre-route so the rule lives
/// in one place.
bool isNativeBlockedTorrent(VideoSource source) =>
    isTorrentUrl(source.url) || source.container == SourceContainer.torrent;

/// Tracks failed engines for the current episode without changing saved choices.
class PlayerEngineFallback {
  (String, String)? _episode;
  final _failed = <String, Set<PlaybackEngine>>{};

  PlaybackEngine? next({
    required bool enabled,
    required PlaybackEngine failedEngine,
    required String episodeUrl,
    required String category,
    required VideoSource source,
  }) {
    if (!enabled || source.isDrm) {
      return null;
    }
    if (isNativeBlockedTorrent(source) &&
        failedEngine != PlaybackEngine.nativePlayer) {
      // mpv plays torrents itself; bouncing one to native is an instant
      // error loop. The reverse (native yielding to mpv) is allowed below.
      return null;
    }
    final scope = (episodeUrl, category);
    if (_episode != scope) {
      _episode = scope;
      _failed.clear();
    }
    final failed = _failed.putIfAbsent(source.url, () => {});
    if (!failed.add(failedEngine)) return null;
    final other = failedEngine == PlaybackEngine.mpv
        ? PlaybackEngine.nativePlayer
        : PlaybackEngine.mpv;
    return failed.contains(other) ? null : other;
  }

  Set<String> blockedUrls(String episodeUrl, String category) =>
      _episode == (episodeUrl, category)
      ? {
          for (final entry in _failed.entries)
            if (entry.value.length == 2) entry.key,
        }
      : {};
}
