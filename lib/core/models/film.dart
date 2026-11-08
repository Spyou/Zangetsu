import '../zmode/zmode_ids.dart';
import 'episode.dart';
import 'media_detail.dart';
import 'provider_info.dart';

/// True when this title plays as one continuous video — a film.
///
/// Metadata first, so a partial source listing (an airing show with one
/// episode out) can never be misread: a zm movie url, an AniList MOVIE
/// format, or a TMDB movie id all say "film" outright. Only a metadata-less
/// title falls back to the single-entry heuristic, and then only when the
/// entry is titled like the whole show ("A", "Movie", "Full Movie") — a
/// generic "Episode 1" is an episode, not a film. Without metadata, more
/// than one entry retains the series presentation.
bool isFilmContent({
  required List<Episode> episodes,
  String? showTitle,
  String? format,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? zmUrl,
}) {
  final kind = zmUrl == null ? null : ZmodeIds.parseShow(zmUrl)?.kind;
  if (kind == ZKind.movie) return true;
  if (kind == ZKind.tv || tmdbIsTv) return false;
  final f = format?.trim().toLowerCase();
  if (f != null && f.isNotEmpty) return f == 'movie';
  if (tmdbId != null) return true;
  if (kind == ZKind.anime) return false;
  if (episodes.length != 1) return false;
  final t = episodes.single.title.trim().toLowerCase();
  if (t.isEmpty) return false;
  final show = (showTitle ?? '').trim().toLowerCase();
  return t == show || t == 'movie' || t.startsWith('full movie');
}

/// The detail-screen answer, wired from the model the route already has.
extension MediaDetailFilm on MediaDetail {
  bool get isFilm =>
      type != ProviderType.manga &&
      type != ProviderType.novel &&
      isFilmContent(
        episodes: episodes,
        showTitle: title,
        format: format,
        tmdbId: tmdbId,
        tmdbIsTv: tmdbIsTv,
        zmUrl: url,
      );
}
