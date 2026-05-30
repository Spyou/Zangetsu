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
  type: $enumDecode(_$ProviderTypeEnumMap, json['type']),
  sourceId: json['sourceId'] as String,
);

Map<String, dynamic> _$MediaDetailToJson(MediaDetail instance) =>
    <String, dynamic>{
      'id': instance.id,
      'title': instance.title,
      'englishTitle': instance.englishTitle,
      'cover': instance.cover,
      'coverHeaders': instance.coverHeaders,
      'url': instance.url,
      'description': instance.description,
      'status': _$MediaStatusEnumMap[instance.status]!,
      'genres': instance.genres,
      'studios': instance.studios,
      'episodes': instance.episodes.map((e) => e.toJson()).toList(),
      'type': _$ProviderTypeEnumMap[instance.type]!,
      'sourceId': instance.sourceId,
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
};
