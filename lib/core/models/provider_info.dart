import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'provider_info.g.dart';

/// Content kind a provider serves. `anime`/`movie` are the existing video
/// types; `manga`/`novel` are reading types (see `ContentMode`).
enum ProviderType {
  @JsonValue('anime')
  anime,
  @JsonValue('movie')
  movie,
  @JsonValue('manga')
  manga,
  @JsonValue('novel')
  novel,
}

@JsonSerializable()
class ProviderInfo extends Equatable {
  final String name;
  final String lang;
  final String baseUrl;
  final String? logo;
  final ProviderType type;
  final String? version;

  const ProviderInfo({
    required this.name,
    required this.lang,
    required this.baseUrl,
    this.logo,
    required this.type,
    this.version,
  });

  factory ProviderInfo.fromJson(Map<String, dynamic> json) =>
      _$ProviderInfoFromJson(json);
  Map<String, dynamic> toJson() => _$ProviderInfoToJson(this);

  @override
  List<Object?> get props => [name, lang, baseUrl, logo, type, version];
}
