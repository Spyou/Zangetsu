import 'package:zangetsu_source_bridge/stremio.dart';

import '../models/video_source.dart';
import '../playback/subtitle_language.dart';
import '../torrent/torrent_util.dart';
import 'stremio_link_session.dart';
import 'stremio_ref.dart';

/// Converts a playable Stremio link for the existing player.
VideoSource? stremioVideoSource(
  StremioLinkChoice choice, {
  List<Subtitle> extraSubtitles = const [],
  String? streamAddonName,
  bool allowTorrent = true,
}) {
  final stream = choice.stream;
  final seen = <String>{};
  final subtitles = <Subtitle>[
    for (final subtitle in [
      for (final track in stream.subtitles)
        Subtitle(
          url: track.url,
          lang: track.lang,
          label: languageOfSource(track.lang)?.name ?? track.lang,
          format: track.format,
          providerName: streamAddonName,
        ),
      ...extraSubtitles,
    ])
      if (seen.add(subtitle.url)) subtitle,
  ];

  final quality = stremioStreamQuality(
    '${stream.name ?? ''} ${stream.description ?? ''}',
  );

  if (stream.kind == StremioStreamKind.direct) {
    final url = stream.url;
    if (url == null) return null;
    return VideoSource(
      url: url,
      quality: quality,
      label: choice.label,
      container: stremioStreamContainer(url),
      headers: stream.headers.isEmpty ? null : stream.headers,
      subtitles: subtitles,
    );
  }

  if (stream.kind == StremioStreamKind.torrent && allowTorrent) {
    final hash = stream.infoHash;
    if (hash == null) return null;
    final magnet = buildTorrentMagnet(
      infoHash: hash,
      trackers: stream.trackers,
      fileIndex: stream.fileIndex,
    );
    if (magnet == null) return null;
    return VideoSource(
      url: magnet,
      quality: quality,
      label: choice.label,
      container: SourceContainer.torrent,
      torrentFileIndex: stream.fileIndex,
      subtitles: subtitles,
    );
  }
  return null;
}

String? stremioStreamQuality(String text) {
  final match = RegExp(
    r'\b(2160p|4k|1080p|720p|480p|360p|cam)\b',
    caseSensitive: false,
  ).firstMatch(text);
  return match?.group(1)?.toLowerCase();
}

String stremioStreamLabel(StremioStream stream) {
  final parts = [
    if (stream.name != null && stream.name!.isNotEmpty) stream.name!,
    if (stream.description != null && stream.description!.isNotEmpty)
      stream.description!,
  ];
  return parts.isEmpty ? 'Stream' : parts.join(' · ');
}

SourceContainer stremioStreamContainer(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  if (path.endsWith('.m3u8')) return SourceContainer.hls;
  if (path.endsWith('.mp4') || path.endsWith('.mkv')) {
    return SourceContainer.mp4;
  }
  return SourceContainer.unknown;
}

String stremioPlayerPackage(
  String sourceId,
  VideoSource? seed,
  String preferred,
) => sourceId == stremioSourceId && seed != null && isTorrentUrl(seed.url)
    ? ''
    : preferred;

List<VideoSource>? stremioSeedSources(String sourceId, VideoSource? seed) =>
    sourceId == stremioSourceId && seed != null ? [seed] : null;
