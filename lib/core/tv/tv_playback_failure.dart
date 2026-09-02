import '../di/injector.dart';
import '../mode/content_mode.dart';
import '../mode/content_mode_cubit.dart';
import '../repository/source_repository.dart';
import '../zmode/source_matcher.dart';
import '../zmode/playback_resolver.dart';
import '../zmode/zmode_ids.dart';

enum TvPlaybackLoadFailureKind {
  /// No streaming/manga/novel extensions installed for this mode.
  noSourcesInstalled,

  /// Sources exist but none matched this metadata title.
  noSourceMatch,

  /// A source matched the show but not this episode / returned no streams.
  episodeNotAvailable,

  /// Network, Cloudflare, or other unexpected failure.
  generic,
}

class TvPlaybackLoadFailure {
  const TvPlaybackLoadFailure(this.kind, {this.mode});

  final TvPlaybackLoadFailureKind kind;
  final ContentMode? mode;
}

ContentMode playbackContentMode({String? showUrl}) {
  final c = showUrl != null ? ZmodeIds.parseShow(showUrl) : null;
  if (c != null) {
    return switch (c.kind) {
      ZKind.manga => ContentMode.manga,
      ZKind.novel => ContentMode.novel,
      _ => ContentMode.anime,
    };
  }
  if (sl.isRegistered<ContentModeCubit>()) {
    return sl<ContentModeCubit>().state;
  }
  return ContentMode.anime;
}

bool hasInstalledPlaybackSources(ContentMode mode) {
  final all = sl<SourceRepository>().pickableSources;
  return switch (mode) {
    ContentMode.manga => all.any((s) => s.id.startsWith('mihon:')),
    ContentMode.novel => all.any((s) => s.id.startsWith('lnr:')),
    ContentMode.anime => all.any(
      (s) => !s.id.startsWith('mihon:') && !s.id.startsWith('lnr:'),
    ),
  };
}

TvPlaybackLoadFailure classifyPlaybackError(
  Object? error, {
  required ContentMode mode,
}) {
  if (error is EpisodeNotAvailable) {
    return TvPlaybackLoadFailure(
      error.hadTitleMatch
          ? TvPlaybackLoadFailureKind.episodeNotAvailable
          : TvPlaybackLoadFailureKind.noSourceMatch,
      mode: mode,
    );
  }
  if (error is NoSourceMatch) {
    return TvPlaybackLoadFailure(
      hasInstalledPlaybackSources(mode)
          ? TvPlaybackLoadFailureKind.noSourceMatch
          : TvPlaybackLoadFailureKind.noSourcesInstalled,
      mode: mode,
    );
  }
  return TvPlaybackLoadFailure(TvPlaybackLoadFailureKind.generic, mode: mode);
}

TvPlaybackLoadFailure? noSourcesFailureForPlay({String? showUrl}) {
  final mode = playbackContentMode(showUrl: showUrl);
  if (hasInstalledPlaybackSources(mode)) return null;
  return TvPlaybackLoadFailure(
    TvPlaybackLoadFailureKind.noSourcesInstalled,
    mode: mode,
  );
}
