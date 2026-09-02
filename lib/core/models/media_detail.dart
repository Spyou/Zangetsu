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

  /// Wide 16:9 art (AniList `bannerImage` / TMDB `backdrop_path`), for the
  /// detail hero. Null outside Z Mode — every existing source keeps
  /// rendering its hero from [cover], exactly as before this field existed.
  final String? banner;
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

  // ── Metadata extras ───────────────────────────────────────────────────────
  // Everything below comes from a metadata provider and is absent for a
  // source-only title, so every one is nullable or empty rather than
  // defaulted — a missing score must read as "unknown", never as zero.

  /// Average score out of 100.
  final int? score;

  /// TV / Movie / OVA / ONA / Special / Manga / Novel, as the provider spells
  /// it.
  final String? format;

  /// Minutes per episode.
  final int? durationMins;

  /// When the next episode airs, and which one. Both or neither — a countdown
  /// with no episode number is not worth showing.
  final DateTime? airingAt;
  final int? nextEpisode;

  /// AniList's tags, most relevant first. Richer than [genres]: they carry a
  /// percentage and a spoiler flag.
  final List<MediaTag> tags;

  final DateTime? startDate;
  final DateTime? endDate;

  /// What it was adapted from — Manga, Light novel, Original, Game.
  final String? sourceMaterial;

  /// ISO country code. Separates anime from donghua and aeni, which the
  /// format alone does not.
  final String? country;

  /// How many people have it on a list. Ranking signal, not a score.
  final int? popularity;

  /// The title in its own script.
  final String? nativeTitle;

  /// Alternate titles. Shown on the details tab, and useful when matching this
  /// title against a source that files it under another name.
  final List<String> synonyms;

  final bool isAdult;

  const MediaDetail({
    required this.id,
    required this.title,
    this.englishTitle,
    this.cover,
    this.coverHeaders,
    this.banner,
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
    this.score,
    this.format,
    this.durationMins,
    this.airingAt,
    this.nextEpisode,
    this.tags = const [],
    this.startDate,
    this.endDate,
    this.sourceMaterial,
    this.country,
    this.popularity,
    this.nativeTitle,
    this.synonyms = const [],
    this.isAdult = false,
  });

  factory MediaDetail.fromJson(Map<String, dynamic> json) =>
      _$MediaDetailFromJson(json);
  Map<String, dynamic> toJson() => _$MediaDetailToJson(this);

  MediaDetail copyWith({
    String? id,
    String? title,
    String? englishTitle,
    String? cover,
    Map<String, String>? coverHeaders,
    String? banner,
    String? url,
    String? description,
    MediaStatus? status,
    List<String>? genres,
    List<String>? studios,
    List<Episode>? episodes,
    List<String>? cast,
    String? year,
    ProviderType? type,
    String? sourceId,
    int? subCount,
    int? dubCount,
    int? malId,
    int? tmdbId,
    bool? tmdbIsTv,
    String? imdbId,
    List<CastMember>? castMembers,
    List<MediaRelation>? relations,
    int? score,
    String? format,
    int? durationMins,
    DateTime? airingAt,
    int? nextEpisode,
    List<MediaTag>? tags,
    DateTime? startDate,
    DateTime? endDate,
    String? sourceMaterial,
    String? country,
    int? popularity,
    String? nativeTitle,
    List<String>? synonyms,
    bool? isAdult,
  }) => MediaDetail(
    id: id ?? this.id,
    title: title ?? this.title,
    englishTitle: englishTitle ?? this.englishTitle,
    cover: cover ?? this.cover,
    coverHeaders: coverHeaders ?? this.coverHeaders,
    banner: banner ?? this.banner,
    url: url ?? this.url,
    description: description ?? this.description,
    status: status ?? this.status,
    genres: genres ?? this.genres,
    studios: studios ?? this.studios,
    episodes: episodes ?? this.episodes,
    cast: cast ?? this.cast,
    year: year ?? this.year,
    type: type ?? this.type,
    sourceId: sourceId ?? this.sourceId,
    subCount: subCount ?? this.subCount,
    dubCount: dubCount ?? this.dubCount,
    malId: malId ?? this.malId,
    tmdbId: tmdbId ?? this.tmdbId,
    tmdbIsTv: tmdbIsTv ?? this.tmdbIsTv,
    imdbId: imdbId ?? this.imdbId,
    castMembers: castMembers ?? this.castMembers,
    relations: relations ?? this.relations,
    score: score ?? this.score,
    format: format ?? this.format,
    durationMins: durationMins ?? this.durationMins,
    airingAt: airingAt ?? this.airingAt,
    nextEpisode: nextEpisode ?? this.nextEpisode,
    tags: tags ?? this.tags,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    sourceMaterial: sourceMaterial ?? this.sourceMaterial,
    country: country ?? this.country,
    popularity: popularity ?? this.popularity,
    nativeTitle: nativeTitle ?? this.nativeTitle,
    synonyms: synonyms ?? this.synonyms,
    isAdult: isAdult ?? this.isAdult,
  );

  @override
  List<Object?> get props => [
    id,
    title,
    englishTitle,
    cover,
    coverHeaders,
    banner,
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
    score,
    format,
    durationMins,
    airingAt,
    nextEpisode,
    tags,
    startDate,
    endDate,
    sourceMaterial,
    country,
    popularity,
    nativeTitle,
    synonyms,
    isAdult,
  ];
}

/// One AniList tag: a descriptor with how strongly voters think it applies.
@JsonSerializable()
class MediaTag extends Equatable {
  const MediaTag({required this.name, this.rank, this.isSpoiler = false});

  factory MediaTag.fromJson(Map<String, dynamic> json) =>
      _$MediaTagFromJson(json);
  Map<String, dynamic> toJson() => _$MediaTagToJson(this);

  final String name;

  /// 0-100: how many voters agree it applies.
  final int? rank;

  /// Spoils the plot. Kept rather than dropped so the page can hide it behind
  /// a tap instead of deciding for the reader.
  final bool isSpoiler;

  @override
  List<Object?> get props => [name, rank, isSpoiler];
}
