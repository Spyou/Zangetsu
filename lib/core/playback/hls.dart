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
