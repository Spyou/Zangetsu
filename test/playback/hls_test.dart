import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/hls.dart';

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
}
