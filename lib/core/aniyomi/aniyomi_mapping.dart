import '../models/episode.dart';
import '../models/media_detail.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/video_source.dart';

// ── SAnime status constants (from SAnime.kt companion object) ─────────────────
//   0 = UNKNOWN, 1 = ONGOING, 2 = COMPLETED, 3 = LICENSED,
//   4 = PUBLISHING_FINISHED, 5 = CANCELLED, 6 = ON_HIATUS

MediaStatus _statusFromInt(int? v) {
  switch (v) {
    case 1:
      return MediaStatus.ongoing;
    case 2:
      return MediaStatus.completed;
    case 5:
      return MediaStatus.cancelled;
    case 6:
      return MediaStatus.hiatus;
    default:
      return MediaStatus.unknown;
  }
}

/// Splits the comma-separated `genre` field from SAnime into a Dart list.
List<String> _parseGenres(String? genre) {
  if (genre == null || genre.isEmpty) return const [];
  return genre
      .split(',')
      .map((g) => g.trim())
      .where((g) => g.isNotEmpty)
      .toList();
}

// ─────────────────────────────────────────────────────────────────────────────
// Public mapping functions
// ─────────────────────────────────────────────────────────────────────────────

/// Converts one SAnime JSON object (from getPopular / getLatest / search) into
/// a [MediaItem].  [sourceId] must be the caller's `'ani:<id>'` string.
///
/// [headers] are the source's default HTTP headers (Referer/User-Agent).
/// When non-empty they are forwarded as [MediaItem.coverHeaders] so the image
/// widget can supply them when fetching the thumbnail — preventing 403 errors
/// on strict image hosts.
///
/// Expected JSON keys (from the native bridge — see Task 7 contract):
///   url           — String  (non-null; opaque source key)
///   title         — String
///   thumbnail_url — String? (cover image)
MediaItem mediaItemFromSAnime(
  Map<String, dynamic> j, {
  required String sourceId,
  Map<String, String>? headers,
}) {
  final url = (j['url'] as String?) ?? '';
  // Build coverHeaders. When headers are provided we also inject 'x-ani-src'
  // (the numeric portion of sourceId) as an internal marker. The image widgets
  // in poster_card / detail_screen use this key to route to AniyomiImage
  // instead of CachedNetworkImage. The key is never sent over the network.
  Map<String, String>? coverHeaders;
  if (headers != null && headers.isNotEmpty) {
    final numericId =
        sourceId.startsWith('ani:') ? sourceId.substring(4) : sourceId;
    coverHeaders = {...headers, 'x-ani-src': numericId};
  }
  return MediaItem(
    id: url,
    title: (j['title'] as String?) ?? '',
    cover: j['thumbnail_url'] as String?,
    coverHeaders: coverHeaders,
    url: url,
    type: ProviderType.anime,
    sourceId: sourceId,
  );
}

/// Converts one SAnime JSON object (from getDetails) + a pre-fetched episode
/// list into a [MediaDetail].  [sourceId] must be the caller's `'ani:<id>'`
/// string.
///
/// [headers] are the source's default HTTP headers (Referer/User-Agent).
/// When non-empty they are forwarded as [MediaDetail.coverHeaders] so the
/// image widget can supply them when fetching the cover — preventing 403
/// errors on strict image hosts.
///
/// Expected JSON keys (from the native bridge — see Task 7 contract):
///   url           — String
///   title         — String
///   thumbnail_url — String?
///   description   — String?
///   genre         — String? (comma-separated, e.g. "Action, Comedy")
///   status        — int    (0=unknown, 1=ongoing, 2=completed, 5=cancelled, 6=hiatus)
MediaDetail mediaDetailFromSAnime(
  Map<String, dynamic> j,
  List<Episode> episodes, {
  required String sourceId,
  Map<String, String>? headers,
}) {
  final url = (j['url'] as String?) ?? '';
  // Same x-ani-src marker injection as in mediaItemFromSAnime — detail banner
  // uses the same AniyomiImage guard in detail_screen.dart.
  Map<String, String>? coverHeaders;
  if (headers != null && headers.isNotEmpty) {
    final numericId =
        sourceId.startsWith('ani:') ? sourceId.substring(4) : sourceId;
    coverHeaders = {...headers, 'x-ani-src': numericId};
  }
  return MediaDetail(
    id: url,
    title: (j['title'] as String?) ?? '',
    cover: j['thumbnail_url'] as String?,
    coverHeaders: coverHeaders,
    url: url,
    description: j['description'] as String?,
    status: _statusFromInt((j['status'] as num?)?.toInt()),
    genres: _parseGenres(j['genre'] as String?),
    episodes: episodes,
    type: ProviderType.anime,
    sourceId: sourceId,
  );
}

/// Converts one SEpisode JSON object into an [Episode].
///
/// The source `url` (Aniyomi's opaque episode key) is stored in [Episode.url]
/// and passed back verbatim to getVideoList.
///
/// Expected JSON keys (from the native bridge — see Task 7 contract):
///   url            — String  (opaque episode key; passed to getVideoList)
///   name           — String  (episode title, e.g. "Episode 1")
///   episode_number — double  (use -1.0 / negative to signal "unset")
///   date_upload    — int     (Unix millis; 0 = unset)
///   fillermark     — bool
///   preview_url    — String? (episode thumbnail)
Episode episodeFromSEpisode(Map<String, dynamic> j) {
  final url = (j['url'] as String?) ?? '';
  final rawNum = (j['episode_number'] as num?)?.toDouble();
  // Aniyomi uses -1.0 as the "no episode number" sentinel.
  final epNum = (rawNum != null && rawNum >= 0) ? rawNum : null;

  // Derive a stable id: prefer episode-number key so watch-history survives URL
  // changes; fall back to the raw URL for specials / unordered episodes.
  final id = epNum != null ? 'ep-${epNum.toStringAsFixed(1)}' : url;

  String? dateStr;
  final dateUpload = (j['date_upload'] as num?)?.toInt();
  if (dateUpload != null && dateUpload > 0) {
    dateStr = DateTime.fromMillisecondsSinceEpoch(dateUpload).toIso8601String();
  }

  return Episode(
    id: id.isNotEmpty ? id : url,
    title: (j['name'] as String?) ?? '',
    number: epNum,
    url: url,
    date: dateStr,
    thumbnail: j['preview_url'] as String?,
    filler: (j['fillermark'] as bool?) ?? false,
  );
}

/// Converts one Video JSON object (from getVideoList) into a [VideoSource].
///
/// Container is inferred from the URL extension: `.m3u8` → HLS, everything
/// else → MP4 (Aniyomi extensions rarely expose DASH or torrent links).
///
/// Expected JSON keys (from the native bridge — see Task 7 contract):
///   videoUrl       — String  (direct stream URL)
///   videoTitle     — String? (quality label, e.g. "1080p")
///   headers        — JSON object mapping header name to value (nullable)
///   subtitleTracks — array of {url:String, lang:String} objects
///   audioTracks    — array of {url:String, lang:String} objects (informational)
VideoSource videoSourceFromVideo(Map<String, dynamic> j) {
  final videoUrl = (j['videoUrl'] as String?) ?? '';
  final lowerUrl = videoUrl.toLowerCase();
  final container =
      lowerUrl.endsWith('.m3u8') ? SourceContainer.hls : SourceContainer.mp4;

  // Headers arrive as a JSON object {"Referer":"https://..."}
  Map<String, String>? headers;
  final rawHeaders = j['headers'];
  if (rawHeaders is Map && rawHeaders.isNotEmpty) {
    headers = {
      for (final e in rawHeaders.entries) '${e.key}': '${e.value}',
    };
  }

  // Subtitle tracks: [{url, lang}]
  final subtitles = <Subtitle>[];
  final rawSubs = j['subtitleTracks'];
  if (rawSubs is List) {
    for (final s in rawSubs) {
      if (s is Map) {
        final subUrl = (s['url'] as String?) ?? '';
        if (subUrl.isNotEmpty) {
          subtitles.add(
            Subtitle(url: subUrl, lang: (s['lang'] as String?) ?? ''),
          );
        }
      }
    }
  }

  final quality = j['videoTitle'] as String?;
  // Hidden local-proxy fallback for Cloudflare-walled streams (see VideoSource).
  final proxyUrl = j['proxyUrl'] as String?;

  return VideoSource(
    url: videoUrl,
    quality: (quality?.isNotEmpty == true) ? quality : null,
    container: container,
    headers: (headers != null && headers.isEmpty) ? null : headers,
    subtitles: subtitles,
    proxyUrl: (proxyUrl?.isNotEmpty == true) ? proxyUrl : null,
  );
}
