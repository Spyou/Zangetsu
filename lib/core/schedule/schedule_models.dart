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
  });

  final int? malId;
  final String title;
  final String? coverUrl;
  final int episode;
  final DateTime airsAtLocal;
  final String format;

  @override
  List<Object?> get props =>
      [malId, title, coverUrl, episode, airsAtLocal, format];
}

/// One upcoming movie/TV title (from TMDB upcoming / on_the_air).
class ComingSoonEntry extends Equatable {
  const ComingSoonEntry({
    required this.tmdbId,
    required this.isTv,
    required this.title,
    required this.posterUrl,
    required this.releaseDate,
  });

  final int tmdbId;
  final bool isTv;
  final String title;
  final String? posterUrl;
  final DateTime? releaseDate;

  @override
  List<Object?> get props => [tmdbId, isTv, title, posterUrl, releaseDate];
}
