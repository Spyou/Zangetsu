import 'package:dio/dio.dart';

/// One selectable quality from an HLS master playlist.
class HlsVariant {
  HlsVariant({required this.quality, required this.url});
  final String quality; // e.g. '1080p'
  final String url;
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
    final String quality;
    final int rank;
    if (res != null) {
      final h = int.parse(res.group(2)!);
      quality = '${h}p';
      rank = h;
    } else {
      final bw = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
      final kbps = bw != null ? (int.parse(bw.group(1)!) ~/ 1000) : 0;
      quality = kbps > 0 ? '${kbps}k' : 'auto';
      rank = kbps;
    }
    out.add(_RankedVariant(quality: quality, url: _resolve(uri, masterUrl), rank: rank));
  }
  out.sort((a, b) => b.rank.compareTo(a.rank));
  return out.cast<HlsVariant>();
}

class _RankedVariant extends HlsVariant {
  _RankedVariant({required super.quality, required super.url, required this.rank});
  final int rank;
}

/// Fetches [masterUrl] and parses it into variants. Returns `[]` on any error or
/// if it's not a master playlist.
Future<List<HlsVariant>> fetchHlsVariants(
    String masterUrl, Map<String, String>? headers, Dio dio) async {
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
