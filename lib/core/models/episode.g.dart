// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'episode.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Episode _$EpisodeFromJson(Map<String, dynamic> json) => Episode(
  id: json['id'] as String,
  title: json['title'] as String,
  number: (json['number'] as num?)?.toDouble(),
  url: json['url'] as String,
  date: json['date'] as String?,
  thumbnail: json['thumbnail'] as String?,
  filler: json['filler'] as bool? ?? false,
);

Map<String, dynamic> _$EpisodeToJson(Episode instance) => <String, dynamic>{
  'id': instance.id,
  'title': instance.title,
  'number': instance.number,
  'url': instance.url,
  'date': instance.date,
  'thumbnail': instance.thumbnail,
  'filler': instance.filler,
};
