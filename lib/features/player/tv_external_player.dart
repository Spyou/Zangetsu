import 'package:flutter/foundation.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/external_player.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/tv_track_helpers.dart' show tvEpisodeUrl;
import '../../core/playback/watch_history.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/tv/tv_playback_failure.dart';
import '../../core/zmode/playback_resolver.dart';
import '../../core/zmode/source_matcher.dart';

/// Result of handing a TV episode to an external player.
enum TvExternalPlayOutcome {
  /// External app took the stream. On TV the native side acknowledges the
  /// hand-off immediately (separate task) so we are not blocked for the whole
  /// VLC session; phone may still report a position when the player returns.
  launched,

  /// This stream can't / shouldn't go external — caller should fall through to
  /// the built-in TV Exo player for this attempt.
  useBuiltIn,

  /// Resolution failed before any player opened. See [TvExternalPlayer.lastFailure].
  failed,
}

/// Resolves one episode and hands it to the configured Android external player
/// (VLC, MX, …) via [ExternalPlayer], the same channel the phone uses.
///
/// Episode switching / next-episode stay in the external app when it supports
/// them; we only hand off the current episode URL (same model as phone).
class TvExternalPlayer {
  /// Set when [play] fails during source resolution.
  static TvPlaybackLoadFailure? lastFailure;

  /// Returns how the hand-off went. [useBuiltIn] means the caller should open
  /// the native/platform-view TV player for this same request.
  static Future<TvExternalPlayOutcome> play({
    required String sourceId,
    required List<Episode> episodes,
    required int startIndex,
    required ResumeStore resume,
    required Future<List<VideoSource>> Function(String episodeUrl)
        resolveSources,
    required String package,
    String? showUrl,
    String? showTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    String category = 'sub',
    int? malId,
    String? scrobbleTitle,
    int? tmdbId,
    bool tmdbIsTv = false,
    String? imdbId,
  }) async {
    lastFailure = null;
    if (!isExternalPlayerPackage(package)) {
      debugPrint(
        '[tv-ext-player] package="$package" is not external → useBuiltIn',
      );
      return TvExternalPlayOutcome.useBuiltIn;
    }
    if (startIndex < 0 || startIndex >= episodes.length) {
      lastFailure = const TvPlaybackLoadFailure(
        TvPlaybackLoadFailureKind.generic,
      );
      return TvExternalPlayOutcome.failed;
    }

    final ep = episodes[startIndex];
    final showId = showUrl ?? sourceId;
    final prefer = category == 'dub' ? AudioKind.dub : AudioKind.sub;

    late final VideoSource src;
    try {
      final url = tvEpisodeUrl(ep.url, category);
      debugPrint('[tv-ext-player] resolve · $url pkg=$package');
      final sources = await resolveSources(url);
      final picked = pickDefault(sources, prefer: prefer);
      if (picked == null) {
        lastFailure = const TvPlaybackLoadFailure(
          TvPlaybackLoadFailureKind.episodeNotAvailable,
        );
        debugPrint('[tv-ext-player] resolve → no stream');
        return TvExternalPlayOutcome.failed;
      }
      src = picked;
    } on NoSourceMatch catch (e) {
      lastFailure = classifyPlaybackError(
        e,
        mode: playbackContentMode(showUrl: showUrl),
      );
      rethrow;
    } on EpisodeNotAvailable catch (e) {
      lastFailure = classifyPlaybackError(
        e,
        mode: playbackContentMode(showUrl: showUrl),
      );
      rethrow;
    } catch (e) {
      lastFailure = TvPlaybackLoadFailure(
        TvPlaybackLoadFailureKind.generic,
        mode: playbackContentMode(showUrl: showUrl),
      );
      debugPrint('[tv-ext-player] resolve → ERROR $e');
      return TvExternalPlayOutcome.failed;
    }

    var playUrl = src.url;
    var launchHeaders = src.headers ?? const <String, String>{};
    final bridge = ExternalPlayer();
    switch (externalHandoffFor(
      url: src.url,
      headers: src.headers,
      package: package,
    )) {
      case ExternalHandoff.builtIn:
        debugPrint(
          '[tv-ext-player] handoff=builtIn (torrent/DASH) → useBuiltIn',
        );
        return TvExternalPlayOutcome.useBuiltIn;
      case ExternalHandoff.direct:
        break;
      case ExternalHandoff.proxy:
        final local = await bridge.proxyStreamUrl(src.url, src.headers!);
        if (local == null) {
          debugPrint('[tv-ext-player] proxy failed → useBuiltIn');
          return TvExternalPlayOutcome.useBuiltIn;
        }
        playUrl = local;
        launchHeaders = const <String, String>{};
    }

    // Scrobble at hand-off — external apps don't feed our tracker.
    final epNum = ep.number;
    if (epNum != null && epNum > 0 && epNum == epNum.truncateToDouble()) {
      if (sl.isRegistered<TrackerHub>()) {
        sl<TrackerHub>().scrobble(
          malId: malId,
          title: scrobbleTitle,
          tmdbId: tmdbId,
          tmdbIsTv: tmdbIsTv,
          imdbId: imdbId,
          episode: epNum.toInt(),
          season: ep.season,
          seasonEpisode: seasonEpisodeOf(episodes, ep),
        );
      }
    }

    final mark = resume.get(sourceId, showId, ep.id);
    final subs = src.subtitles
        .map(
          (s) => {
            'url': s.url,
            'name': s.label ?? s.lang,
            'default': s.isDefault.toString(),
          },
        )
        .toList();
    final title = [
      showTitle,
      ep.title,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' • ');

    debugPrint(
      '[tv-ext-player] launch pkg=$package '
      'pos=${mark?.position.inMilliseconds ?? 0}',
    );
    final res = await bridge.launch(
      url: playUrl,
      package: package,
      title: title.isEmpty ? null : title,
      headers: launchHeaders,
      subtitles: subs,
      positionMs: mark?.position.inMilliseconds ?? 0,
    );

    if (!res.launched) {
      debugPrint('[tv-ext-player] launch failed → useBuiltIn');
      return TvExternalPlayOutcome.useBuiltIn;
    }

    // Persist whatever position the external player reported on return.
    final posMs = res.positionMs;
    if (posMs > 0) {
      final dur = mark?.duration ?? Duration.zero;
      resume.save(
        sourceId,
        showId,
        ep.id,
        Duration(milliseconds: posMs),
        dur.inMilliseconds > 0 ? dur : Duration(milliseconds: posMs),
      );
      if (sl.isRegistered<WatchHistory>()) {
        sl<WatchHistory>().save(
          HistoryEntry(
            sourceId: sourceId,
            showId: showId,
            showTitle: showTitle ?? '',
            cover: cover,
            coverHeaders: coverHeaders,
            showUrl: showUrl ?? '',
            category: category,
            episodeId: ep.id,
            episodeNumber: ep.number,
            episodeUrl: ep.url,
            position: Duration(milliseconds: posMs),
            duration: dur.inMilliseconds > 0
                ? dur
                : Duration(milliseconds: posMs),
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            malId: malId,
          ),
        );
      }
    }

    debugPrint('[tv-ext-player] launched ok · posMs=$posMs');
    return TvExternalPlayOutcome.launched;
  }
}
