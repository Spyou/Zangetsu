// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'media_detail.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MediaDetail _$MediaDetailFromJson(Map<String, dynamic> json) => MediaDetail(
  id: json['id'] as String,
  title: json['title'] as String,
  englishTitle: json['englishTitle'] as String?,
  cover: json['cover'] as String?,
  coverHeaders: (json['coverHeaders'] as Map<String, dynamic>?)?.map(
    (k, e) => MapEntry(k, e as String),
  ),
  banner: json['banner'] as String?,
  url: json['url'] as String,
  description: json['description'] as String?,
  status:
      $enumDecodeNullable(
        _$MediaStatusEnumMap,
        json['status'],
        unknownValue: MediaStatus.unknown,
      ) ??
      MediaStatus.unknown,
  genres:
      (json['genres'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      [],
  studios:
      (json['studios'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      [],
  episodes:
      (json['episodes'] as List<dynamic>?)
          ?.map((e) => Episode.fromJson(e as Map<String, dynamic>))
          .toList() ??
      [],
  cast:
      (json['cast'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
  year: json['year'] as String?,
  type: $enumDecode(_$ProviderTypeEnumMap, json['type']),
  sourceId: json['sourceId'] as String,
  subCount: (json['subCount'] as num?)?.toInt(),
  dubCount: (json['dubCount'] as num?)?.toInt(),
  malId: (json['malId'] as num?)?.toInt(),
  tmdbId: (json['tmdbId'] as num?)?.toInt(),
  tmdbIsTv: json['tmdbIsTv'] as bool? ?? false,
  imdbId: json['imdbId'] as String?,
  score: (json['score'] as num?)?.toInt(),
  format: json['format'] as String?,
  durationMins: (json['durationMins'] as num?)?.toInt(),
  airingAt: json['airingAt'] == null
      ? null
      : DateTime.parse(json['airingAt'] as String),
  nextEpisode: (json['nextEpisode'] as num?)?.toInt(),
  tags:
      (json['tags'] as List<dynamic>?)
          ?.map((e) => MediaTag.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const [],
  startDate: json['startDate'] == null
      ? null
      : DateTime.parse(json['startDate'] as String),
  endDate: json['endDate'] == null
      ? null
      : DateTime.parse(json['endDate'] as String),
  sourceMaterial: json['sourceMaterial'] as String?,
  country: json['country'] as String?,
  popularity: (json['popularity'] as num?)?.toInt(),
  nativeTitle: json['nativeTitle'] as String?,
  synonyms:
      (json['synonyms'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const [],
  isAdult: json['isAdult'] as bool? ?? false,
);

Map<String, dynamic> _$MediaDetailToJson(MediaDetail instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'englishTitle': instance.englishTitle,
      'cover': instance.cover,
      'coverHeaders': instance.coverHeaders,
      'banner': instance.banner,
      'url': instance.url,
      'description': instance.description,
      'status': _$MediaStatusEnumMap[instance.status]!,
      'genres': instance.genres,
      'studios': instance.studios,
      'episodes': instance.episodes.map((e) => e.toJson()).toList(),
      'cast': instance.cast,
      'year': instance.year,
      'type': _$ProviderTypeEnumMap[instance.type]!,
      'sourceId': instance.sourceId,
      'subCount': instance.subCount,
      'dubCount': instance.dubCount,
      'malId': instance.malId,
      'tmdbId': instance.tmdbId,
      'tmdbIsTv': instance.tmdbIsTv,
      'imdbId': instance.imdbId,
      'score': instance.score,
      'format': instance.format,
      'durationMins': instance.durationMins,
      'airingAt': instance.airingAt?.toIso8601String(),
      'nextEpisode': instance.nextEpisode,
      'tags': instance.tags.map((e) => e.toJson()).toList(),
      'startDate': instance.startDate?.toIso8601String(),
      'endDate': instance.endDate?.toIso8601String(),
      'sourceMaterial': instance.sourceMaterial,
      'country': instance.country,
      'popularity': instance.popularity,
      'nativeTitle': instance.nativeTitle,
      'synonyms': instance.synonyms,
      'isAdult': instance.isAdult,
    };

const _$MediaStatusEnumMap = {
  MediaStatus.ongoing: 'ongoing',
  MediaStatus.completed: 'completed',
  MediaStatus.hiatus: 'hiatus',
  MediaStatus.cancelled: 'cancelled',
  MediaStatus.unknown: 'unknown',
};

const _$ProviderTypeEnumMap = {
  ProviderType.anime: 'anime',
  ProviderType.movie: 'movie',
  ProviderType.manga: 'manga',
  ProviderType.novel: 'novel',
};

MediaTag _$MediaTagFromJson(Map<String, dynamic> json) => MediaTag(
  name: json['name'] as String,
  rank: (json['rank'] as num?)?.toInt(),
  isSpoiler: json['isSpoiler'] as bool? ?? false,
);

Map<String, dynamic> _$MediaTagToJson(MediaTag instance) => <String, dynamic>{
  'name': instance.name,
  'rank': instance.rank,
  'isSpoiler': instance.isSpoiler,
};
