import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/hls.dart';

/// Answers every request with a canned body and records what was asked for,
/// so the Range header the sniff adds (and the plain path's lack of one) is
/// verifiable without a network.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.body);
  final String body;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? s,
      Future<void>? cancelFuture) async {
    seen.add(options);
    return ResponseBody.fromString(body, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('parseHlsMaster returns variants sorted high→low with absolute urls', () {
    const master = '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=854x480\n'
        '480/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080\n'
        'https://cdn.test/1080/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720\n'
        '720/index.m3u8\n';
    final out = parseHlsMaster(master, 'https://cdn.test/hls/master.m3u8');
    expect(out.map((v) => v.quality).toList(), ['1080p', '720p', '480p']);
    expect(out[0].url, 'https://cdn.test/1080/index.m3u8'); // absolute kept
    expect(out[1].url, 'https://cdn.test/hls/720/index.m3u8'); // relative resolved
  });

  test('parseHlsMaster returns empty for a non-master playlist', () {
    const media = '#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n#EXTINF:6.0,\nseg1.ts\n';
    expect(parseHlsMaster(media, 'https://cdn.test/x/index.m3u8'), isEmpty);
  });

  test('parseHlsMaster falls back to a bandwidth label when RESOLUTION is absent', () {
    const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000\na/index.m3u8\n';
    final out = parseHlsMaster(master, 'https://cdn.test/hls/master.m3u8');
    expect(out.single.quality, '1200k');
    expect(out.single.url, 'https://cdn.test/hls/a/index.m3u8');
  });

  group('is this really HLS?', () {
    test('looksLikeHlsUrl reads the path, not the query', () {
      expect(looksLikeHlsUrl('https://cdn.test/a/master.m3u8'), isTrue);
      expect(looksLikeHlsUrl('https://cdn.test/a/master.m3u8?token=abc'), isTrue);
      expect(looksLikeHlsUrl('https://cdn.test/a/video.mp4'), isFalse);
      // The extension only in a query value doesn't make it a playlist.
      expect(looksLikeHlsUrl('https://cdn.test/play?src=x.m3u8'), isFalse);
    });

    const master = '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080\n'
        '1080/i.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=854x480\n'
        '480/i.m3u8\n';

    test('a known playlist is fetched exactly as before — no Range header', () async {
      final a = _RecordingAdapter(master);
      final dio = Dio()..httpClientAdapter = a;
      final out = await fetchHlsVariants('https://cdn.test/m.m3u8', null, dio);
      expect(out.map((v) => v.quality), ['1080p', '480p']);
      expect(a.seen.single.headers.containsKey('Range'), isFalse,
          reason: 'a Range some CDNs answer with 416 must not reach the '
              'path that already works');
    });

    test('a suspected playlist is sniffed with a bounded Range', () async {
      final a = _RecordingAdapter(master);
      final dio = Dio()..httpClientAdapter = a;
      final out = await fetchHlsVariants(
          'https://cdn.test/stream?id=9', null, dio, sniff: true);
      expect(out.map((v) => v.quality), ['1080p', '480p'],
          reason: 'this is the MovieBox case: no m3u8 flag, no .m3u8 in the '
              'url, but a real master behind it');
      expect(a.seen.single.headers['Range'], 'bytes=0-65535');
    });

    test('sniffing something that is not a playlist yields nothing', () async {
      // An mp4 body: without the #EXTM3U guard this would be parsed as text.
      final a = _RecordingAdapter('\u0000\u0000\u0000 ftypmp42binary...');
      final dio = Dio()..httpClientAdapter = a;
      expect(
        await fetchHlsVariants('https://cdn.test/v.mp4', null, dio, sniff: true),
        isEmpty,
      );
    });
  });
}
