// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'provider_info.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ProviderInfo _$ProviderInfoFromJson(Map<String, dynamic> json) => ProviderInfo(
  name: json['name'] as String,
  lang: json['lang'] as String,
  baseUrl: json['baseUrl'] as String,
  logo: json['logo'] as String?,
  type: $enumDecode(_$ProviderTypeEnumMap, json['type']),
  version: json['version'] as String?,
);

Map<String, dynamic> _$ProviderInfoToJson(ProviderInfo instance) =>
    <String, dynamic>{
      'name': instance.name,
      'lang': instance.lang,
      'baseUrl': instance.baseUrl,
      'logo': instance.logo,
      'type': _$ProviderTypeEnumMap[instance.type]!,
      'version': instance.version,
    };

const _$ProviderTypeEnumMap = {
  ProviderType.anime: 'anime',
  ProviderType.movie: 'movie',
};
