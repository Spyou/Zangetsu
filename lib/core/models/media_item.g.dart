// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'media_item.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

MediaItem _$MediaItemFromJson(Map<String, dynamic> json) => MediaItem(
  id: json['id'] as String,
  title: json['title'] as String,
  englishTitle: json['englishTitle'] as String?,
  cover: json['cover'] as String?,
  coverHeaders: (json['coverHeaders'] as Map<String, dynamic>?)?.map(
    (k, e) => MapEntry(k, e as String),
  ),
  banner: json['banner'] as String?,
  url: json['url'] as String,
  type: $enumDecode(_$ProviderTypeEnumMap, json['type']),
  sourceId: json['sourceId'] as String,
  dubBadge: json['dubBadge'] as String?,
  subCount: (json['subCount'] as num?)?.toInt(),
  dubCount: (json['dubCount'] as num?)?.toInt(),
  savedFrom: json['savedFrom'] as String?,
  savedAtMs: (json['savedAtMs'] as num?)?.toInt(),
  malId: (json['malId'] as num?)?.toInt(),
  tmdbId: (json['tmdbId'] as num?)?.toInt(),
  tmdbIsTv: json['tmdbIsTv'] as bool? ?? false,
  imdbId: json['imdbId'] as String?,
  genres:
      (json['genres'] as List<dynamic>?)?.map((e) => e as String).toList() ??
      const [],
  status: $enumDecodeNullable(_$MediaStatusEnumMap, json['status']),
);

Map<String, dynamic> _$MediaItemToJson(MediaItem instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'englishTitle': instance.englishTitle,
  'cover': instance.cover,
  'coverHeaders': instance.coverHeaders,
  'banner': instance.banner,
  'url': instance.url,
  'type': _$ProviderTypeEnumMap[instance.type]!,
  'sourceId': instance.sourceId,
  'dubBadge': instance.dubBadge,
  'subCount': instance.subCount,
  'dubCount': instance.dubCount,
  'malId': instance.malId,
  'tmdbId': instance.tmdbId,
  'tmdbIsTv': instance.tmdbIsTv,
  'imdbId': instance.imdbId,
  'savedFrom': instance.savedFrom,
  'savedAtMs': instance.savedAtMs,
  'genres': instance.genres,
  'status': _$MediaStatusEnumMap[instance.status],
};

const _$ProviderTypeEnumMap = {
  ProviderType.anime: 'anime',
  ProviderType.movie: 'movie',
  ProviderType.manga: 'manga',
  ProviderType.novel: 'novel',
};

const _$MediaStatusEnumMap = {
  MediaStatus.ongoing: 'ongoing',
  MediaStatus.completed: 'completed',
  MediaStatus.hiatus: 'hiatus',
  MediaStatus.cancelled: 'cancelled',
  MediaStatus.unknown: 'unknown',
};
