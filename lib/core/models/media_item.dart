import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

import 'provider_info.dart';

part 'media_item.g.dart';

/// One row in a search / browse listing. The video-native analogue of
/// Sozo Read's `BookItem`.
@JsonSerializable()
class MediaItem extends Equatable {
  final String id;
  final String title;

  /// Optional romanized / English alternative title. Null when the source
  /// doesn't provide one; UI falls back to [title].
  final String? englishTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String url;
  final ProviderType type;
  final String sourceId;
  final int? subCount;
  final int? dubCount;

  const MediaItem({
    required this.id,
    required this.title,
    this.englishTitle,
    this.cover,
    this.coverHeaders,
    required this.url,
    required this.type,
    required this.sourceId,
    this.subCount,
    this.dubCount,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) =>
      _$MediaItemFromJson(json);
  Map<String, dynamic> toJson() => _$MediaItemToJson(this);

  MediaItem copyWith({String? sourceId, int? subCount, int? dubCount}) => MediaItem(
        id: id,
        title: title,
        englishTitle: englishTitle,
        cover: cover,
        coverHeaders: coverHeaders,
        url: url,
        type: type,
        sourceId: sourceId ?? this.sourceId,
        subCount: subCount ?? this.subCount,
        dubCount: dubCount ?? this.dubCount,
      );

  @override
  List<Object?> get props =>
      [id, title, englishTitle, cover, coverHeaders, url, type, sourceId, subCount, dubCount];
}
