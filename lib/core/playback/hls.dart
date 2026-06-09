import 'package:dio/dio.dart';

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

/// Fetches [masterUrl] and parses it into variants. Returns `[]` on any error or
/// if it's not a master playlist.
Future<List<HlsVariant>> fetchHlsVariants(
  String masterUrl,
  Map<String, String>? headers,
  Dio dio,
) async {
  try {
    final resp = await dio.getUri<String>(
      Uri.parse(masterUrl),
      options: Options(
        responseType: ResponseType.plain,
        headers: headers,
        receiveTimeout: const Duration(seconds: 8),
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    final body = resp.data ?? '';
    return parseHlsMaster(body, masterUrl);
  } catch (_) {
    return const [];
  }
}
