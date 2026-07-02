import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

part 'video_source.g.dart';

/// Stream container. `unknown` lets a provider omit the hint; the player
/// then sniffs by URL extension.
enum SourceContainer {
  @JsonValue('hls')
  hls,
  @JsonValue('mp4')
  mp4,
  @JsonValue('torrent')
  torrent,
  @JsonValue('unknown')
  unknown,
}

/// Audio track intent for a source. Drives the sub/dub picker.
enum AudioKind {
  @JsonValue('sub')
  sub,
  @JsonValue('dub')
  dub,
  @JsonValue('raw')
  raw,
  @JsonValue('unknown')
  unknown,
}

@JsonSerializable()
class Subtitle extends Equatable {
  final String url;
  final String lang;
  final String? label;

  /// `'vtt'` or `'srt'`. Free-form so a source can pass through anything
  /// the player accepts.
  final String? format;

  @JsonKey(name: 'default', defaultValue: false)
  final bool isDefault;

  const Subtitle({
    required this.url,
    required this.lang,
    this.label,
    this.format,
    this.isDefault = false,
  });

  factory Subtitle.fromJson(Map<String, dynamic> json) =>
      _$SubtitleFromJson(json);
  Map<String, dynamic> toJson() => _$SubtitleToJson(this);

  @override
  List<Object?> get props => [url, lang, label, format, isDefault];
}

/// A single playable stream for an episode. The video-native analogue of
/// Sozo Read's `PageContent`. A provider returns a LIST of these; the UI
/// filters by [kind]/[audioLang]/[quality].
@JsonSerializable(explicitToJson: true)
class VideoSource extends Equatable {
  final String url;
  final String? quality;

  /// Optional human-friendly name for this stream, shown in the player's
  /// Sources sheet (e.g. "4K HDHub · FSL Server [WEB-DL] [2GB]"). When absent
  /// the sheet falls back to the quality / container. Lets a provider that
  /// exposes many mirrors label each one distinctly instead of every row
  /// reading the same "2160p".
  final String? label;

  @JsonKey(
    unknownEnumValue: SourceContainer.unknown,
    defaultValue: SourceContainer.unknown,
  )
  final SourceContainer container;

  final Map<String, String>? headers;

  @JsonKey(unknownEnumValue: AudioKind.unknown, defaultValue: AudioKind.unknown)
  final AudioKind kind;

  final String? audioLang;

  @JsonKey(defaultValue: <Subtitle>[])
  final List<Subtitle> subtitles;

  const VideoSource({
    required this.url,
    this.quality,
    this.label,
    this.container = SourceContainer.unknown,
    this.headers,
    this.kind = AudioKind.unknown,
    this.audioLang,
    this.subtitles = const [],
  });

  factory VideoSource.fromJson(Map<String, dynamic> json) =>
      _$VideoSourceFromJson(json);
  Map<String, dynamic> toJson() => _$VideoSourceToJson(this);

  @override
  List<Object?> get props => [
    url,
    quality,
    label,
    container,
    headers,
    kind,
    audioLang,
    subtitles,
  ];
}
