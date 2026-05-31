import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'episode.dart';
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

  @JsonKey(unknownEnumValue: MediaStatus.unknown,
      defaultValue: MediaStatus.unknown)
  final MediaStatus status;

  @JsonKey(defaultValue: <String>[])
  final List<String> genres;

  @JsonKey(defaultValue: <String>[])
  final List<String> studios;

  @JsonKey(defaultValue: <Episode>[])
  final List<Episode> episodes;

  final ProviderType type;
  final String sourceId;
  final int? subCount;
  final int? dubCount;

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
    required this.type,
    required this.sourceId,
    this.subCount,
    this.dubCount,
  });

  factory MediaDetail.fromJson(Map<String, dynamic> json) =>
      _$MediaDetailFromJson(json);
  Map<String, dynamic> toJson() => _$MediaDetailToJson(this);

  @override
  List<Object?> get props => [
        id, title, englishTitle, cover, coverHeaders, url, description,
        status, genres, studios, episodes, type, sourceId, subCount, dubCount,
      ];
}
