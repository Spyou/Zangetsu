import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../l10n/l10n.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/repository/source_repository.dart';
import '../../core/tv/tv_load_error_dialog.dart';
import '../../core/tv/tv_playback_failure.dart';
import '../../core/zmode/playback_resolver.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/zmode/zmode_ids.dart';
import '../shell/tv_source_picker.dart';
import 'tv_av_native_player.dart';
import 'tv_exo_player_screen.dart';
import 'tv_native_player.dart';

/// Which TV player backend to use.
enum TvPlayerKind {
  /// Stock AVPlayerViewController (Apple TV).
  avPlayerSystem,

  nativeExo,
  exoView,
}

/// Pure routing: Apple TV always uses system AVKit; Android TV keeps native
/// Exo vs platform-view.
TvPlayerKind tvPlayerKind({
  required bool appleTv,
  required bool nativeTvPlayer,
}) {
  if (appleTv) return TvPlayerKind.avPlayerSystem;
  if (nativeTvPlayer) return TvPlayerKind.nativeExo;
  return TvPlayerKind.exoView;
}

/// When no playback sources are installed for [showUrl]'s mode, shows the TV
/// install-sources dialog and returns false.
Future<bool> ensureTvPlaybackSourcesOrPrompt(
  BuildContext context, {
  String? showUrl,
}) async {
  debugPrint(
    '[tv-playback] ensureTvPlaybackSourcesOrPrompt · showUrl=$showUrl',
  );
  final failure = noSourcesFailureForPlay(showUrl: showUrl);
  if (failure == null) {
    debugPrint('[tv-playback] ensureTvPlaybackSourcesOrPrompt → sources OK');
    return true;
  }
  debugPrint(
    '[tv-playback] ensureTvPlaybackSourcesOrPrompt → BLOCKED · $failure',
  );
  if (!context.mounted) return false;
  await showTvPlaybackLoadError(context, failure: failure);
  return false;
}

/// Routes a TV play request to the platform player.
///
/// When [skipOverlay] is true the blocking "Finding …" overlay is suppressed
/// — the caller is already confident the source works (e.g. Continue Watching
/// resume) so there's no need to cover the screen while sources resolve.
Future<void> launchTvPlayback({
  required BuildContext context,
  required String sourceId,
  required List<Episode> episodes,
  required int startIndex,
  required ResumeStore resume,
  required Future<List<VideoSource>> Function(String episodeUrl) resolveSources,
  String? showUrl,
  String? showTitle,
  String? cover,
  Map<String, String>? coverHeaders,
  String category = 'sub',
  List<String> availableCategories = const [],
  int? malId,
  String? scrobbleTitle,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? imdbId,
  bool skipOverlay = false,
}) async {
  debugPrint(
    '[tv-playback] launchTvPlayback · sourceId=$sourceId '
    'episodes=${episodes.length} startIdx=$startIndex '
    'showUrl=$showUrl showTitle=$showTitle category=$category',
  );
  final mode = playbackContentMode(showUrl: showUrl);
  if (!await ensureTvPlaybackSourcesOrPrompt(context, showUrl: showUrl)) {
    return;
  }

  final prefs = sl<PlaybackPrefs>();
  final kind = tvPlayerKind(
    appleTv: isAppleTv,
    nativeTvPlayer: prefs.nativeTvPlayer,
  );
  debugPrint(
    '[tv-playback] launchTvPlayback · playerKind=$kind '
    'appleTv=$isAppleTv nativeTvPlayer=${prefs.nativeTvPlayer}',
  );

  TvPlaybackLoadFailure? resolveFailure;
  Future<List<VideoSource>> trackedResolve(String url) async {
    debugPrint('[tv-playback] resolveSources · $url');
    try {
      final streams = await resolveSources(url);
      debugPrint(
        '[tv-playback] resolveSources → ${streams.length} streams '
        'for $url',
      );
      if (streams.isEmpty) {
        resolveFailure ??= const TvPlaybackLoadFailure(
          TvPlaybackLoadFailureKind.episodeNotAvailable,
        );
        debugPrint('[tv-playback] resolveSources → EMPTY streams');
      }
      return streams;
    } catch (e) {
      resolveFailure ??= classifyPlaybackError(e, mode: mode);
      debugPrint('[tv-playback] resolveSources → ERROR $e');
      rethrow;
    }
  }

  final loadingMessage = (showTitle != null && showTitle.trim().isNotEmpty)
      ? context.l10n.findingTitle(showTitle.trim())
      : context.l10n.loading;
  VoidCallback? dismissLoading;
  // Skip the blocking overlay when the caller already trusts the source
  // (Continue Watching resume) — the native player loads immediately and
  // avoids the full-screen "Finding …" cover while sources resolve.
  if (!skipOverlay && kind != TvPlayerKind.exoView && context.mounted) {
    dismissLoading = showTvPlaybackLoadingOverlay(
      context,
      message: loadingMessage,
    );
  }

  try {
    if (kind == TvPlayerKind.avPlayerSystem) {
      TvAvNativePlayer.lastFailure = null;
      final started = await TvAvNativePlayer.play(
        sourceId: sourceId,
        episodes: episodes,
        startIndex: startIndex,
        resume: resume,
        resolveSources: trackedResolve,
        showUrl: showUrl,
        showTitle: showTitle,
        cover: cover,
        coverHeaders: coverHeaders,
        category: category,
        availableCategories: availableCategories,
        malId: malId,
        scrobbleTitle: scrobbleTitle,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
      );
      if (!started && context.mounted) {
        // Dismiss the loading overlay BEFORE showing the error dialog so
        // the user doesn't see both the overlay and the dialog simultaneously.
        dismissLoading?.call();
        await showTvPlaybackLoadError(
          context,
          failure: TvAvNativePlayer.lastFailure ??
              resolveFailure ??
              TvPlaybackLoadFailure(TvPlaybackLoadFailureKind.generic, mode: mode),
        );
      }
      return;
    }

    if (kind == TvPlayerKind.nativeExo) {
      TvNativePlayer.lastFailure = null;
      TvNativePlayer.lastPlaybackErrorCode = null;
      final started = await TvNativePlayer.play(
        sourceId: sourceId,
        episodes: episodes,
        startIndex: startIndex,
        resume: resume,
        resolveSources: trackedResolve,
        showUrl: showUrl,
        showTitle: showTitle,
        cover: cover,
        coverHeaders: coverHeaders,
        category: category,
        availableCategories: availableCategories,
        malId: malId,
        scrobbleTitle: scrobbleTitle,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
      );
      if (!started && context.mounted) {
        dismissLoading?.call();
        await showTvPlaybackLoadError(
          context,
          failure: TvNativePlayer.lastFailure ??
              resolveFailure ??
              TvPlaybackLoadFailure(TvPlaybackLoadFailureKind.generic, mode: mode),
        );
        return;
      }
      // A fatal ExoPlayer error (stream resolved, but the player couldn't
      // decode/play it) — offer Try Next Source / Select Source / Close.
      // Only meaningful when the catalogue can sweep other sources (zm
      // metadata); for a direct source there's nothing else to try, so just
      // surface the generic error dialog.
      final errorCode = TvNativePlayer.lastPlaybackErrorCode;
      if (errorCode != null) {
        dismissLoading?.call();
        final isZm = (showUrl != null && ZmodeIds.isZ(showUrl));
        if (!isZm && context.mounted) {
          await showTvPlaybackLoadError(
            context,
            failure: TvPlaybackLoadFailure(
              TvPlaybackLoadFailureKind.generic,
              mode: mode,
            ),
          );
        } else if (context.mounted) {
          await _handleTvPlaybackFailure(
            context,
            errorCode: errorCode,
            showTitle: showTitle ?? showUrl ?? sourceId,
            showUrl: showUrl,
            launchAgain: () => launchTvPlayback(
              context: context,
              sourceId: sourceId,
              episodes: episodes,
              startIndex: startIndex,
              resume: resume,
              resolveSources: resolveSources,
              showUrl: showUrl,
              showTitle: showTitle,
              cover: cover,
              coverHeaders: coverHeaders,
              category: category,
              availableCategories: availableCategories,
              malId: malId,
              scrobbleTitle: scrobbleTitle,
              tmdbId: tmdbId,
              tmdbIsTv: tmdbIsTv,
              imdbId: imdbId,
              skipOverlay: true,
            ),
          );
        }
      }
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TvExoPlayerScreen(
          sourceId: sourceId,
          episodes: episodes,
          startIndex: startIndex,
          resume: resume,
          resolveSources: trackedResolve,
          showUrl: showUrl,
          showTitle: showTitle,
          cover: cover,
          coverHeaders: coverHeaders,
          category: category,
          availableCategories: availableCategories,
          malId: malId,
          scrobbleTitle: scrobbleTitle,
          tmdbId: tmdbId,
          tmdbIsTv: tmdbIsTv,
          imdbId: imdbId,
        ),
      ),
    );
  } on NoSourceMatch catch (e) {
    debugPrint('[tv-playback] launchTvPlayback · NoSourceMatch caught · $e');
    if (context.mounted) {
      await showTvPlaybackLoadError(
        context,
        failure: classifyPlaybackError(e, mode: mode),
      );
    }
  } on EpisodeNotAvailable catch (e) {
    debugPrint(
      '[tv-playback] launchTvPlayback · EpisodeNotAvailable caught · $e',
    );
    if (context.mounted) {
      await showTvPlaybackLoadError(
        context,
        failure: classifyPlaybackError(e, mode: mode),
      );
    }
  } finally {
    dismissLoading?.call();
  }
}

/// Handles a fatal playback error from the native player (the stream resolved
/// but ExoPlayer couldn't play it). Asks the user what to do:
///
///  - **Try Next Source**: re-runs resolution. The failed source was already
///    marked unhealthy + its winner cache invalidated by [TvNativePlayer], so
///    the re-resolve sweeps to the next candidate automatically.
///  - **Select Source**: opens the TV source picker; the picked source is made
///    the preferred one (via SourceMatcher), then playback re-launches.
///  - **Close**: just dismisses.
Future<void> _handleTvPlaybackFailure(
  BuildContext context, {
  required String errorCode,
  required String showTitle,
  required String? showUrl,
  required Future<void> Function() launchAgain,
}) async {
  final action = await showTvPlaybackErrorDialog(
    context,
    errorCode: errorCode,
    showTitle: showTitle,
  );
  debugPrint('[tv-playback] _handleTvPlaybackFailure · action=$action');
  switch (action) {
    case TvPlaybackErrorAction.tryNext:
      debugPrint('[tv-playback] _handleTvPlaybackFailure → relaunch (next source)');
      await launchAgain();
    case TvPlaybackErrorAction.selectSource:
      await _pickSourceAndRelaunch(context, showUrl, launchAgain);
    case TvPlaybackErrorAction.close:
      break;
  }
}

/// Opens the TV source picker; the picked source becomes the preferred one for
/// this kind (SourceMatcher), then playback re-launches so the resolver routes
/// through the user's choice.
Future<void> _pickSourceAndRelaunch(
  BuildContext context,
  String? showUrl,
  Future<void> Function() launchAgain,
) async {
  if (!context.mounted) return;
  final currentId =
      sl.isRegistered<SourceRepository>() ? sl<SourceRepository>().sourceId : '';
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => TvSourcePicker(
      currentId: currentId,
      onPick: (id) async {
        // Make the picked source preferred for this title's kind so the
        // resolver ranks it first (the failed one is already dead).
        final c = showUrl != null ? ZmodeIds.parseShow(showUrl) : null;
        if (c != null && sl.isRegistered<SourceMatcher>()) {
          await sl<SourceMatcher>().selectSource(c.kind, id);
        }
        Navigator.of(ctx).pop();
        await launchAgain();
      },
    ),
  );
}
