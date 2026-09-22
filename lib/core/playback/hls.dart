import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// One selectable quality from an HLS master playlist.
class HlsVariant {
  HlsVariant({required this.quality, required this.url, this.bandwidth = 0});
  final String quality; // e.g. '1080p'
  final String url;

  /// The variant's `BANDWIDTH` (bits/s), 0 when the master omits it. Used to
  /// pin the quality via mpv's `hls-bitrate` while keeping the master open
  /// (so separately-muxed audio renditions aren't lost).
  final int bandwidth;
}

/// Resolves [ref] (which may be relative) against the directory of [base].
String _resolve(String ref, String base) {
  if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
  final b = Uri.parse(base);
  return b.resolve(ref).toString();
}

/// Parses an HLS master playlist into its variant streams, sorted highest
/// resolution first. Returns `[]` if [playlist] has no `#EXT-X-STREAM-INF`
/// (i.e. it's a media playlist, not a master).
List<HlsVariant> parseHlsMaster(String playlist, String masterUrl) {
  final lines = playlist.split(RegExp(r'\r?\n'));
  final out = <_RankedVariant>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    String? uri;
    for (var j = i + 1; j < lines.length; j++) {
      final cand = lines[j].trim();
      if (cand.isEmpty || cand.startsWith('#')) continue;
      uri = cand;
      break;
    }
    if (uri == null) continue;
    final res = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(line);
    final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
    final bandwidth = bwMatch != null ? int.parse(bwMatch.group(1)!) : 0;
    final String quality;
    final int rank;
    if (res != null) {
      final h = int.parse(res.group(2)!);
      quality = '${h}p';
      rank = h;
    } else {
      final kbps = bandwidth ~/ 1000;
      quality = kbps > 0 ? '${kbps}k' : 'auto';
      rank = kbps;
    }
    out.add(
      _RankedVariant(
        quality: quality,
        url: _resolve(uri, masterUrl),
        rank: rank,
        bandwidth: bandwidth,
      ),
    );
  }
  out.sort((a, b) => b.rank.compareTo(a.rank));
  return out.cast<HlsVariant>();
}

class _RankedVariant extends HlsVariant {
  _RankedVariant({
    required super.quality,
    required super.url,
    required this.rank,
    required super.bandwidth,
  });
  final int rank;
}

/// One alternate audio rendition (`#EXT-X-MEDIA:TYPE=AUDIO`) from a master.
class HlsAudioRendition {
  HlsAudioRendition({
    required this.uri,
    required this.lang,
    required this.name,
    required this.isDefault,
    this.channels = '',
  });
  final String uri;
  final String lang;
  final String name;
  final bool isDefault;

  /// The master's own CHANNELS attribute, a count as text ("2", "6"). Empty
  /// when the playlist doesn't say.
  ///
  /// Worth carrying because it is the only way to tell a stereo track from a
  /// 5.1 one WITHOUT opening it, and opening them all is exactly what this
  /// file exists to avoid.
  final String channels;
}

/// Value of [key] in an `#EXT-X-...` attribute list, quoted or bare.
String? hlsAttr(String line, String key) {
  final m = RegExp('$key=(?:"([^"]*)"|([^,]*))').firstMatch(line);
  return m?.group(1) ?? m?.group(2);
}

/// Alternate audio tracks named by a master playlist, in file order.
///
/// FFmpeg (so mpv) opens EVERY one of these and downloads a couple of segments
/// from each just to learn its codec — 18 of them on a Netflix-style stream is
/// half a minute before the first frame. ExoPlayer reads the same attributes
/// and downloads nothing, which is why CloudStream starts quickly on the exact
/// same link. Parsing them here lets us hand mpv a master with one audio track
/// and attach the rest on demand.
List<HlsAudioRendition> parseHlsAudioRenditions(
  String playlist,
  String masterUrl,
) {
  final out = <HlsAudioRendition>[];
  for (final raw in playlist.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (!line.startsWith('#EXT-X-MEDIA:')) continue;
    if (hlsAttr(line, 'TYPE') != 'AUDIO') continue;
    final uri = hlsAttr(line, 'URI');
    if (uri == null || uri.isEmpty) continue;
    out.add(
      HlsAudioRendition(
        uri: _resolve(uri, masterUrl),
        lang: hlsAttr(line, 'LANGUAGE') ?? '',
        name: hlsAttr(line, 'NAME') ?? '',
        channels: hlsAttr(line, 'CHANNELS') ?? '',
        isDefault: (hlsAttr(line, 'DEFAULT') ?? '').toUpperCase() == 'YES',
      ),
    );
  }
  return out;
}

/// [playlist] rewritten to keep every video variant but only the audio
/// rendition whose resolved URI is [keepUri]. All URIs are made absolute so the
/// result plays from a local file. Returns null if [keepUri] isn't in there.
String? buildTrimmedMaster(String playlist, String masterUrl, String keepUri) {
  final lines = playlist.split(RegExp(r'\r?\n'));
  final out = <String>[];
  var kept = false;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.startsWith('#EXT-X-MEDIA:') && hlsAttr(line, 'TYPE') == 'AUDIO') {
      final uri = hlsAttr(line, 'URI');
      if (uri == null) continue;
      final abs = _resolve(uri, masterUrl);
      if (abs != keepUri) continue; // the 17 we never play
      out.add(line.replaceFirst('URI="$uri"', 'URI="$abs"'));
      kept = true;
      continue;
    }
    // A bare line after a STREAM-INF is a variant URI — absolutise it.
    if (line.isNotEmpty && !line.startsWith('#')) {
      out.add(_resolve(line, masterUrl));
      continue;
    }
    out.add(raw);
  }
  if (!kept) return null;
  return out.join('\n');
}

/// Whether [url] names a playlist by its path. Query-aware: plenty of CDNs
/// hang `?token=...` off the end, and a few put `.m3u8` in a query value only,
/// which doesn't count.
bool looksLikeHlsUrl(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return path.contains('.m3u8');
}

/// Fetches [masterUrl] and parses it into variants. Returns `[]` on any error or
/// if it's not a master playlist.
///
/// [sniff] is for a source we only SUSPECT is HLS — a plugin that never set its
/// m3u8 flag and whose url doesn't say either. It asks for the first 64 KB
/// instead of the whole body (the url could turn out to be a multi-GB mp4) and
/// insists on the `#EXTM3U` signature before parsing. Left false for a source
/// already known to be HLS, so that path issues exactly the request it always
/// did — a Range header some CDNs answer with a 416 would break what works.
Future<List<HlsVariant>> fetchHlsVariants(
  String masterUrl,
  Map<String, String>? headers,
  Dio dio, {
  bool sniff = false,
}) async {
  try {
    final resp = await dio.getUri<String>(
      Uri.parse(masterUrl),
      options: Options(
        responseType: ResponseType.plain,
        headers: sniff
            ? {...?headers, 'Range': 'bytes=0-65535'}
            : headers,
        receiveTimeout: const Duration(seconds: 8),
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final body = resp.data ?? '';
    debugPrint(
      '[quality] fetch status=${resp.statusCode} len=${body.length}',
    );
    if (sniff && !body.trimLeft().startsWith('#EXTM3U')) return const [];
    return parseHlsMaster(body, masterUrl);
  } catch (e) {
    debugPrint('[quality] fetch failed: $e');
    return const [];
  }
}

/// A subtitle rendition named by an HLS master playlist.
///
/// These live in `#EXT-X-MEDIA:TYPE=SUBTITLES`, which [parseHlsMaster] skips —
/// it only reads `#EXT-X-STREAM-INF` video variants. That is why a downloaded
/// episode came back with no subtitles even when the stream had them: nothing
/// ever looked at this tag, and Android's MediaMuxer cannot carry a subtitle
/// track inside the MP4 either, so there was nowhere for them to survive.
class HlsSubtitleTrack {
  const HlsSubtitleTrack({
    required this.url,
    required this.lang,
    required this.label,
    this.isDefault = false,
  });

  /// The rendition's own playlist (absolute), itself a list of .vtt segments.
  final String url;
  final String lang;
  final String label;
  final bool isDefault;
}

/// Reads an attribute out of an `#EXT-X-MEDIA:` line. Values may be quoted;
/// unquoted ones (YES/NO, plain tokens) are returned as-is.
String? _attr(String line, String name) {
  final m = RegExp('$name=(?:"([^"]*)"|([^,]*))').firstMatch(line);
  if (m == null) return null;
  return (m.group(1) ?? m.group(2))?.trim();
}

/// The subtitle renditions a master playlist offers, in playlist order.
///
/// Returns `[]` for a media playlist, a master with no subtitles, or any entry
/// missing a URI — a rendition we cannot fetch is not worth reporting.
List<HlsSubtitleTrack> parseHlsSubtitles(String playlist, String masterUrl) {
  final out = <HlsSubtitleTrack>[];
  for (final raw in playlist.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (!line.startsWith('#EXT-X-MEDIA:')) continue;
    if (_attr(line, 'TYPE') != 'SUBTITLES') continue;
    final uri = _attr(line, 'URI');
    if (uri == null || uri.isEmpty) continue;
    final lang = _attr(line, 'LANGUAGE') ?? '';
    final name = _attr(line, 'NAME') ?? '';
    out.add(
      HlsSubtitleTrack(
        url: _resolve(uri, masterUrl),
        lang: lang,
        // NAME is what the site shows a viewer; fall back to the language code
        // so a track is never nameless in the picker.
        label: name.isNotEmpty ? name : lang,
        isDefault: (_attr(line, 'DEFAULT') ?? 'NO').toUpperCase() == 'YES',
      ),
    );
  }
  return out;
}
