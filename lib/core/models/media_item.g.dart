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
  url: json['url'] as String,
  type: $enumDecode(_$ProviderTypeEnumMap, json['type']),
  sourceId: json['sourceId'] as String,
  subCount: (json['subCount'] as num?)?.toInt(),
  dubCount: (json['dubCount'] as num?)?.toInt(),
);

Map<String, dynamic> _$MediaItemToJson(MediaItem instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'englishTitle': instance.englishTitle,
  'cover': instance.cover,
  'coverHeaders': instance.coverHeaders,
  'url': instance.url,
  'type': _$ProviderTypeEnumMap[instance.type]!,
  'sourceId': instance.sourceId,
  'subCount': instance.subCount,
  'dubCount': instance.dubCount,
};

const _$ProviderTypeEnumMap = {
  ProviderType.anime: 'anime',
  ProviderType.movie: 'movie',
};
