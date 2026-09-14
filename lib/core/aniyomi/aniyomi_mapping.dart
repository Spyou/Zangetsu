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

/// Same as [_statusFromInt] but folds the "unknown" fallback to null —
/// [MediaItem.status] uses null to mean "this source didn't say", so it stays
/// distinguishable from a status the source actually reported. Only used on
/// the search/browse mapping; the detail mapping keeps the non-null default.
MediaStatus? _itemStatus(int? v) {
  final s = _statusFromInt(v);
  return s == MediaStatus.unknown ? null : s;
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
///   genre         — String? (comma-separated, e.g. "Action, Comedy") — feeds
///                   [MediaItem.genres], same parsing as [mediaDetailFromSAnime].
///   status        — int?   (0=unknown, 1=ongoing, 2=completed, 5=cancelled,
///                   6=hiatus) — feeds [MediaItem.status]; folded to null when
///                   unknown, see [_itemStatus].
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
    final numericId = sourceId.startsWith('ani:')
        ? sourceId.substring(4)
        : sourceId;
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
    genres: _parseGenres(j['genre'] as String?),
    status: _itemStatus((j['status'] as num?)?.toInt()),
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
    final numericId = sourceId.startsWith('ani:')
        ? sourceId.substring(4)
        : sourceId;
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
// ── Sub/dub, as Aniyomi actually expresses it ────────────────────────────────
//
// Aniyomi's API has no sub/dub parameter — `getVideoList(episode)` takes an
// episode and nothing else. A source that carries both cuts says so in each
// video's OWN title ("Dub - 1080p"), so the two arrive as separate entries in
// one list. That word was being read straight into `quality` as if it were a
// resolution, which is why a Dub row was visible but could not be switched to:
// nothing ever set [VideoSource.kind].

/// Matches a whole word only, so "Subaru" is not a sub and "Dublin" is not a
/// dub. Ordered longest-first where prefixes overlap (hardsub before sub).
final RegExp _kAudioMarker = RegExp(
  r'\b(hard[\s-]?sub(?:bed)?|soft[\s-]?sub(?:bed)?|dub(?:bed)?|sub(?:bed)?|raw)\b',
  caseSensitive: false,
);

/// Leftover punctuation once a marker is cut out of a label — "Dub - 1080p"
/// must read "1080p", not "- 1080p".
final RegExp _kOrphanSeparators = RegExp(r'^[\s\-–—·•|:/()\[\]]+|[\s\-–—·•|:/()\[\]]+$');
final RegExp _kDoubledSeparators = RegExp(r'[\s]*([\-–—·•|])[\s]*\1*[\s]*');

/// The audio cut named by a video's title, and that title with the naming
/// removed so it can still serve as the quality label.
///
/// Returns [AudioKind.unknown] when the title says nothing about audio — the
/// overwhelmingly common case, and the one that must keep behaving exactly as
/// it did before.
({AudioKind kind, String? quality}) audioKindFromTitle(String? title) {
  if (title == null || title.trim().isEmpty) {
    return (kind: AudioKind.unknown, quality: null);
  }
  final m = _kAudioMarker.firstMatch(title);
  if (m == null) return (kind: AudioKind.unknown, quality: title);

  final word = m.group(1)!.toLowerCase().replaceAll(RegExp(r'[\s-]'), '');
  final kind = word == 'raw'
      ? AudioKind.raw
      : word.startsWith('dub')
      ? AudioKind.dub
      // hardsub / softsub / sub / subbed all mean the same thing here.
      : AudioKind.sub;

  var rest = title.replaceRange(m.start, m.end, ' ');
  // replaceAllMapped, not replaceAll: r'$1' is a literal there, not a group.
  rest = rest.replaceAllMapped(_kDoubledSeparators, (m) => ' ${m[1]} ');
  rest = rest.replaceAll(_kOrphanSeparators, '').trim();
  rest = rest.replaceAll(RegExp(r'\s{2,}'), ' ');
  return (kind: kind, quality: rest.isEmpty ? null : rest);
}

/// What an entry that names no cut should be taken as.
///
/// Only ever [AudioKind.sub], and only when SOMETHING in the list is marked
/// dub — a list where no title mentions audio gets [AudioKind.unknown] back,
/// so every source that has only ever had one cut keeps the exact kind (and
/// therefore the exact picker, ordering and failover) it had before.
///
/// Takes the raw titles rather than built sources so the decision is made
/// before construction: [VideoSource] has no copyWith, and rebuilding one
/// field by hand is how a newly added field gets silently dropped later.
AudioKind fallbackAudioKind(Iterable<String?> videoTitles) {
  final anyDub = videoTitles.any(
    (t) => audioKindFromTitle(t).kind == AudioKind.dub,
  );
  return anyDub ? AudioKind.sub : AudioKind.unknown;
}

/// else → MP4 (Aniyomi extensions rarely expose DASH or torrent links).
///
/// Expected JSON keys (from the native bridge — see Task 7 contract):
///   videoUrl       — String  (direct stream URL)
///   videoTitle     — String? (quality label, e.g. "1080p")
///   headers        — JSON object mapping header name to value (nullable)
///   subtitleTracks — array of {url:String, lang:String} objects
///   audioTracks    — array of {url:String, lang:String} objects (informational)
VideoSource videoSourceFromVideo(
  Map<String, dynamic> j, {
  AudioKind fallbackKind = AudioKind.unknown,
}) {
  final videoUrl = (j['videoUrl'] as String?) ?? '';
  final lowerUrl = videoUrl.toLowerCase();
  final container = lowerUrl.endsWith('.m3u8')
      ? SourceContainer.hls
      : SourceContainer.mp4;

  // Headers arrive as a JSON object {"Referer":"https://..."}
  Map<String, String>? headers;
  final rawHeaders = j['headers'];
  if (rawHeaders is Map && rawHeaders.isNotEmpty) {
    headers = {for (final e in rawHeaders.entries) '${e.key}': '${e.value}'};
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

  // "Dub - 1080p" is a cut AND a resolution. Split them: the cut drives the
  // audio picker, what remains is still the quality label.
  final audio = audioKindFromTitle(j['videoTitle'] as String?);
  final quality = audio.quality;
  // Hidden local-proxy fallback for Cloudflare-walled streams (see VideoSource).
  final proxyUrl = j['proxyUrl'] as String?;

  return VideoSource(
    url: videoUrl,
    quality: (quality?.isNotEmpty == true) ? quality : null,
    kind: audio.kind == AudioKind.unknown ? fallbackKind : audio.kind,
    container: container,
    headers: (headers != null && headers.isEmpty) ? null : headers,
    subtitles: subtitles,
    proxyUrl: (proxyUrl?.isNotEmpty == true) ? proxyUrl : null,
  );
}
