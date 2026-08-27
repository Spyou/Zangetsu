import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/platform/apple_tv.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/tv/tv_load_error_dialog.dart';
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

/// Routes a TV play request to the platform player.
///
/// Apple TV always uses AVKit [TvSystemPlayerViewController] with transport
/// menus / Episodes tab / Up Next. Android TV keeps native Exo vs
/// platform-view.
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
  final prefs = sl<PlaybackPrefs>();
  final kind = tvPlayerKind(
    appleTv: isAppleTv,
    nativeTvPlayer: prefs.nativeTvPlayer,
  );

  if (kind == TvPlayerKind.avPlayerSystem) {
    final started = await TvAvNativePlayer.play(
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
