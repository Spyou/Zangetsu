import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'episode.dart';
import 'media_extras.dart';
import 'provider_info.dart';

part 'media_detail.g.dart';

enum MediaStatus {
  @JsonValue('ongoing')
  ongoing,
  @JsonValue('completed')
  completed,
  @JsonValue('hiatus')
  hiatus,
  @JsonValue('cancelled')
  cancelled,
  @JsonValue('unknown')
  unknown,
}

/// Full series detail. The video-native analogue of Sozo Read's
/// `BookDetail` (chapters → episodes, authors → studios).
@JsonSerializable(explicitToJson: true)
class MediaDetail extends Equatable {
  final String id;
  final String title;
  final String? englishTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String url;
  final String? description;

  @JsonKey(
    unknownEnumValue: MediaStatus.unknown,
    defaultValue: MediaStatus.unknown,
  )
  final MediaStatus status;

  @JsonKey(defaultValue: <String>[])
  final List<String> genres;

  @JsonKey(defaultValue: <String>[])
  final List<String> studios;

  @JsonKey(defaultValue: <Episode>[])
  final List<Episode> episodes;

  /// Cast members (actors / voice actors). Populated by sources that expose
  /// it (e.g. NetMirror's `post.php` cast field); empty for sources that
  /// don't (e.g. AllAnime). Drives the Cast tab.
  @JsonKey(defaultValue: <String>[])
  final List<String> cast;

  /// Release year, when the source provides it. Null otherwise — the meta
  /// line omits the segment rather than inventing a value.
  final String? year;

  final ProviderType type;
  final String sourceId;
  final int? subCount;
  final int? dubCount;

  /// MyAnimeList id, when the source exposes it (anime). Drives tracker sync
  /// (AniList/MAL/Simkl) — the scrobble target and the list-import match key.
  final int? malId;

  /// TMDB id (movies/series), when the source exposes it. Drives Simkl tracking
  /// for non-anime content; [tmdbIsTv] selects TMDB's movie vs tv namespace.
  final int? tmdbId;
  final bool tmdbIsTv;

  /// IMDb id (e.g. `tt1234567`), when the source exposes it but not a TMDB id.
  /// Also drives Simkl tracking — Simkl accepts an `imdb` id in its ids object.
  final String? imdbId;

  /// Rich cast (name + role + photo) supplied directly by the source, when it
  /// has one (e.g. CloudStream's `actors`). Runtime-only — never persisted.
  /// When present it feeds the Cast tab directly, skipping id-based enrichment.
  @JsonKey(includeFromJson: false, includeToJson: false)
  final List<CastMember> castMembers;

  /// Related/recommended titles supplied directly by the source (e.g.
  /// CloudStream's `recommendations`). Runtime-only — never persisted. When
  /// present it feeds the Relations tab directly, skipping id-based enrichment.
  @JsonKey(includeFromJson: false, includeToJson: false)
  final List<MediaRelation> relations;

  const MediaDetail({
    required this.id,
    required this.title,
    this.englishTitle,
    this.cover,
    this.coverHeaders,
    required this.url,
    this.description,
    this.status = MediaStatus.unknown,
    this.genres = const [],
    this.studios = const [],
    this.episodes = const [],
    this.cast = const [],
    this.year,
    required this.type,
    required this.sourceId,
    this.subCount,
    this.dubCount,
    this.malId,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.imdbId,
    this.castMembers = const [],
    this.relations = const [],
  });

  factory MediaDetail.fromJson(Map<String, dynamic> json) =>
      _$MediaDetailFromJson(json);
  Map<String, dynamic> toJson() => _$MediaDetailToJson(this);

  @override
  List<Object?> get props => [
    id,
    title,
    englishTitle,
    cover,
    coverHeaders,
    url,
    description,
    status,
    genres,
    studios,
    episodes,
    cast,
    year,
    type,
    sourceId,
    subCount,
    dubCount,
    malId,
    tmdbId,
    tmdbIsTv,
    imdbId,
    castMembers,
    relations,
  ];
}
