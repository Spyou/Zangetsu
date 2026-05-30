// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'video_source.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Subtitle _$SubtitleFromJson(Map<String, dynamic> json) => Subtitle(
  url: json['url'] as String,
  lang: json['lang'] as String,
  label: json['label'] as String?,
  format: json['format'] as String?,
  isDefault: json['default'] as bool? ?? false,
);

Map<String, dynamic> _$SubtitleToJson(Subtitle instance) => <String, dynamic>{
  'url': instance.url,
  'lang': instance.lang,
  'label': instance.label,
  'format': instance.format,
  'default': instance.isDefault,
};

VideoSource _$VideoSourceFromJson(Map<String, dynamic> json) => VideoSource(
  url: json['url'] as String,
  quality: json['quality'] as String?,
  container:
      $enumDecodeNullable(
        _$SourceContainerEnumMap,
        json['container'],
        unknownValue: SourceContainer.unknown,
      ) ??
      SourceContainer.unknown,
  headers: (json['headers'] as Map<String, dynamic>?)?.map(
    (k, e) => MapEntry(k, e as String),
  ),
  kind:
      $enumDecodeNullable(
        _$AudioKindEnumMap,
        json['kind'],
        unknownValue: AudioKind.unknown,
      ) ??
      AudioKind.unknown,
  audioLang: json['audioLang'] as String?,
  subtitles:
      (json['subtitles'] as List<dynamic>?)
          ?.map((e) => Subtitle.fromJson(e as Map<String, dynamic>))
          .toList() ??
      [],
);

Map<String, dynamic> _$VideoSourceToJson(VideoSource instance) =>
    <String, dynamic>{
      'url': instance.url,
      'quality': instance.quality,
      'container': _$SourceContainerEnumMap[instance.container]!,
      'headers': instance.headers,
      'kind': _$AudioKindEnumMap[instance.kind]!,
      'audioLang': instance.audioLang,
      'subtitles': instance.subtitles.map((e) => e.toJson()).toList(),
    };

const _$SourceContainerEnumMap = {
  SourceContainer.hls: 'hls',
  SourceContainer.mp4: 'mp4',
  SourceContainer.unknown: 'unknown',
};

const _$AudioKindEnumMap = {
  AudioKind.sub: 'sub',
  AudioKind.dub: 'dub',
  AudioKind.raw: 'raw',
  AudioKind.unknown: 'unknown',
};
