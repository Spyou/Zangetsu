import 'package:equatable/equatable.dart';

/// One anime episode airing event (from AniList AiringSchedule).
class AiringEntry extends Equatable {
  const AiringEntry({
    required this.malId,
    required this.title,
    required this.coverUrl,
    required this.episode,
    required this.airsAtLocal,
    required this.format,
    this.bannerUrl,
    this.synopsis,
  });

  final int? malId;
  final String title;
  final String? coverUrl;
  final int episode;
  final DateTime airsAtLocal;
  final String format;

  /// Wide 16:9 art (AniList `bannerImage`), for the New&Hot backdrop cards.
  /// Often null — the UI falls back to [coverUrl].
  final String? bannerUrl;

  /// Plain-text synopsis (AniList `description`), or null.
  final String? synopsis;

  @override
  List<Object?> get props =>
      [malId, title, coverUrl, episode, airsAtLocal, format, bannerUrl, synopsis];
}

/// One upcoming movie/TV title (from TMDB upcoming / on_the_air).
class ComingSoonEntry extends Equatable {
  const ComingSoonEntry({
    required this.tmdbId,
    required this.isTv,
    required this.title,
    required this.posterUrl,
    required this.releaseDate,
    this.backdropUrl,
    this.synopsis,
  });

  final int tmdbId;
  final bool isTv;
  final String title;
  final String? posterUrl;
  final DateTime? releaseDate;

  /// Wide 16:9 art (TMDB `backdrop_path`); falls back to [posterUrl].
  final String? backdropUrl;

  /// Plain-text synopsis (TMDB `overview`), or null.
  final String? synopsis;

  @override
  List<Object?> get props =>
      [tmdbId, isTv, title, posterUrl, releaseDate, backdropUrl, synopsis];
}
