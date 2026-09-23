import '../../core/models/video_source.dart';

/// Container → MIME hint. A tokenised url carries no extension, so without an
/// explicit MIME ExoPlayer builds the wrong MediaSource and never starts.
String? phoneMimeFor(VideoSource source) {
  final u = source.url.toLowerCase();
  if (source.container == SourceContainer.hls || u.contains('.m3u8')) {
    return 'application/x-mpegURL';
  }
  if (u.contains('.mpd')) return 'application/dash+xml';
  if (u.contains('.mp4')) return 'video/mp4';
  return null;
}

/// Everything [PhonePlayerActivity] needs for one launch, as a flat map.
///
/// Flat on purpose: the Kotlin side reads each value straight off the method
/// call, and [bufferParams] is spread in rather than nested so BufferPresets
/// can read it without knowing this function exists.
Map<String, dynamic> phonePlayerArgs({
  required VideoSource source,
  required int positionMs,
  required String title,
  required String episodeLabel,
  required List<String> episodeLabels,
  required int startIndex,
  required int accentColor,
  required bool softwareDecoding,
  required double defaultSpeed,
  required Map<String, dynamic> bufferParams,
  required double subtitleScale,
  required int subtitleFgColor,
  required int subtitleBgColor,
  required int subtitleEdgeType,
  String? subtitleFontPath,
}) {
  final mime = phoneMimeFor(source);
  return <String, dynamic>{
    'url': source.url,
    'headers': source.headers ?? const <String, String>{},
    'mimeType': ?mime,
    'positionMs': positionMs,
    'title': title,
    'episodeLabel': episodeLabel,
    'episodeLabels': episodeLabels,
    'episodeCount': episodeLabels.length,
    'startIndex': startIndex,
    'subUrls': [for (final s in source.subtitles) s.url],
    'subLangs': [for (final s in source.subtitles) s.lang],
    // Fall back to the language so the picker never shows a blank row.
    'subLabels': [for (final s in source.subtitles) s.label ?? s.lang],
    'accentColor': accentColor,
    'softwareDecoding': softwareDecoding,
    'defaultSpeed': defaultSpeed,
    ...bufferParams,
    'subtitleScale': subtitleScale,
    'subtitleFgColor': subtitleFgColor,
    'subtitleBgColor': subtitleBgColor,
    'subtitleEdgeType': subtitleEdgeType,
    'subtitleFontPath': ?subtitleFontPath,
  };
}
