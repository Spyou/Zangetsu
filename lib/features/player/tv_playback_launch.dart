import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../l10n/l10n.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/tv/tv_load_error_dialog.dart';
import '../../core/tv/tv_playback_failure.dart';
import '../../core/zmode/playback_resolver.dart';
import '../../core/zmode/source_matcher.dart';
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
  final failure = noSourcesFailureForPlay(showUrl: showUrl);
  if (failure == null) return true;
  if (!context.mounted) return false;
  await showTvPlaybackLoadError(context, failure: failure);
  return false;
}

/// Routes a TV play request to the platform player.
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
}) async {
  final mode = playbackContentMode(showUrl: showUrl);
  if (!await ensureTvPlaybackSourcesOrPrompt(context, showUrl: showUrl)) {
    return;
  }

  final prefs = sl<PlaybackPrefs>();
  final kind = tvPlayerKind(
    appleTv: isAppleTv,
    nativeTvPlayer: prefs.nativeTvPlayer,
  );

  TvPlaybackLoadFailure? resolveFailure;
  Future<List<VideoSource>> trackedResolve(String url) async {
    try {
      final streams = await resolveSources(url);
      if (streams.isEmpty) {
        resolveFailure ??= const TvPlaybackLoadFailure(
          TvPlaybackLoadFailureKind.episodeNotAvailable,
        );
      }
      return streams;
    } catch (e) {
      resolveFailure ??= classifyPlaybackError(e, mode: mode);
      rethrow;
    }
  }

  final loadingMessage = (showTitle != null && showTitle.trim().isNotEmpty)
      ? context.l10n.findingTitle(showTitle.trim())
      : context.l10n.loading;
  VoidCallback? dismissLoading;
  if (kind != TvPlayerKind.exoView && context.mounted) {
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
        await showTvPlaybackLoadError(
          context,
          failure: TvNativePlayer.lastFailure ??
              resolveFailure ??
              TvPlaybackLoadFailure(TvPlaybackLoadFailureKind.generic, mode: mode),
        );
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
    if (context.mounted) {
      await showTvPlaybackLoadError(
        context,
        failure: classifyPlaybackError(e, mode: mode),
      );
    }
  } on EpisodeNotAvailable catch (e) {
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
