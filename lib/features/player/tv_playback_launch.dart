import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/tv/tv_load_error_dialog.dart';
import 'tv_av_player_screen.dart';
import 'tv_exo_player_screen.dart';
import 'tv_native_player.dart';

/// Which TV player backend to use.
enum TvPlayerKind { avPlayer, nativeExo, exoView }

/// Pure routing: Apple TV always uses AVPlayer; Android TV keeps the native
/// ExoPlayer Activity vs Flutter platform-view split.
TvPlayerKind tvPlayerKind({
  required bool appleTv,
  required bool nativeTvPlayer,
}) {
  if (appleTv) return TvPlayerKind.avPlayer;
  if (nativeTvPlayer) return TvPlayerKind.nativeExo;
  return TvPlayerKind.exoView;
}

/// Routes a TV play request to the platform player.
///
/// Apple TV always uses AVPlayer ([TvAvPlayerScreen]). Android TV keeps the
/// existing native ExoPlayer Activity vs Flutter platform-view split.
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
  final kind = tvPlayerKind(
    appleTv: isAppleTv,
    nativeTvPlayer: sl<PlaybackPrefs>().nativeTvPlayer,
  );

  if (kind == TvPlayerKind.avPlayer) {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TvAvPlayerScreen(
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
          malId: malId,
        ),
      ),
    );
    return;
  }

  if (kind == TvPlayerKind.nativeExo) {
    final started = await TvNativePlayer.play(
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
    );
    if (!started && context.mounted) await showTvPlaybackLoadError(context);
    return;
  }

  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => TvExoPlayerScreen(
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
      ),
    ),
  );
}
