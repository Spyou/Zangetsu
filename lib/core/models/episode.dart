import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'episode.g.dart';

/// One episode within a series. The video-native analogue of Sozo Read's
/// `Chapter` — same wire keys (`id/title/number/url/date`) plus two video
/// extras.
@JsonSerializable()
class Episode extends Equatable {
  final String id;
  final String title;
  final double? number;
  final String url;
  final String? date;
  final String? thumbnail;

  @JsonKey(defaultValue: false)
  final bool filler;

  const Episode({
    required this.id,
    required this.title,
    this.number,
    required this.url,
    this.date,
    this.thumbnail,
    this.filler = false,
  });

  factory Episode.fromJson(Map<String, dynamic> json) =>
      _$EpisodeFromJson(json);
  Map<String, dynamic> toJson() => _$EpisodeToJson(this);

  @override
  List<Object?> get props => [id, title, number, url, date, thumbnail, filler];
}
