import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/hls_downloader.dart';

Uint8List _encodePts(int pts) {
  final pts3230 = (pts >> 30) & 0x7;
  final pts2915 = (pts >> 15) & 0x7FFF;
  final pts140 = pts & 0x7FFF;
  return Uint8List.fromList([
    0x20 | (pts3230 << 1) | 0x01,
    (pts2915 >> 7) & 0xFF,
    ((pts2915 & 0x7F) << 1) | 0x01,
    (pts140 >> 7) & 0xFF,
    ((pts140 & 0x7F) << 1) | 0x01,
  ]);
}

Uint8List _tsPacket({
  required int pid,
  required int streamId,
  required int pts,
}) {
  final out = Uint8List(188)..fillRange(0, 188, 0xFF);
  out[0] = 0x47;
  out[1] = 0x40 | ((pid >> 8) & 0x1f);
  out[2] = pid & 0xFF;
  out[3] = 0x10;
  var o = 4;
  out[o++] = 0x00;
  out[o++] = 0x00;
  out[o++] = 0x01;
  out[o++] = streamId;
  out[o++] = 0x00;
  out[o++] = 0x00;
  out[o++] = 0x80;
  out[o++] = 0x80; // PTS only
  out[o++] = 0x05;
  out.setRange(o, o + 5, _encodePts(pts));
  return out;
}

Uint8List _tsWithPts(int pts, {int packets = 3}) {
  final first = _tsPacket(pid: 0x100, streamId: 0xE0, pts: pts);
  final out = Uint8List(188 * packets)..fillRange(0, 188 * packets, 0xFF);
  out.setRange(0, 188, first);
  for (var p = 1; p < packets; p++) {
    out[p * 188] = 0x47;
    out[p * 188 + 3] = 0x10;
  }
  return out;
}

void main() {
  test('mpegTsFirstPtsSeconds reads 10s Apple HLS padding (900000/90000)', () {
    expect(mpegTsFirstPtsSeconds(_tsWithPts(900000)), closeTo(10.0, 0.001));
  });

  test('mpegTsFirstPtsSeconds reads 13s padding (1170000/90000)', () {
    expect(mpegTsFirstPtsSeconds(_tsWithPts(1170000)), closeTo(13.0, 0.001));
  });

  test('mpegTsInspect does not treat sub-second PTS as caption origin', () {
    expect(mpegTsInspect(_tsWithPts(15120)).epoch, isNull);
    expect(mpegTsInspect(_tsWithPts(900000)).epoch, closeTo(10.0, 0.001));
  });

  test('hlsUnwrapSegment skips a large JPEG decoy before MPEG-TS', () {
    final jpeg = Uint8List(8000)
      ..[0] = 0xFF
      ..[1] = 0xD8
      ..fillRange(2, 8000, 0x11);
    final ts = _tsWithPts(1170000);
    final wrapped = Uint8List(jpeg.length + ts.length)
      ..setRange(0, jpeg.length, jpeg)
      ..setRange(jpeg.length, jpeg.length + ts.length, ts);
    final unwrapped = hlsUnwrapSegment(wrapped);
    expect(unwrapped, isNotNull);
    expect(mpegTsFirstPtsSeconds(unwrapped!), closeTo(13.0, 0.001));
  });

  test('mpegTsInspect uses first audio PTS when dub audio starts after video', () {
    final video = _tsPacket(pid: 0x100, streamId: 0xE0, pts: 15120);
    final audio = _tsPacket(pid: 0x101, streamId: 0xBD, pts: 1170000);
    final ts = Uint8List(188 * 2)
      ..setRange(0, 188, video)
      ..setRange(188, 376, audio);
    final inspect = mpegTsInspect(ts);
    expect(inspect.videoPts, closeTo(0.168, 0.001));
    expect(inspect.audioPts, closeTo(13.0, 0.001));
    expect(inspect.epoch, closeTo(13.0, 0.001));
  });

  test('hlsMediaSegments sums EXTINF before DISCONTINUITY', () {
    const pl = '#EXTM3U\n'
        '#EXTINF:4.0,\nseg0.ts\n'
        '#EXTINF:4.0,\nseg1.ts\n'
        '#EXTINF:5.0,\nseg2.ts\n'
        '#EXT-X-DISCONTINUITY\n'
        '#EXTINF:4.0,\nseg3.ts\n';
    final segs = hlsMediaSegments(pl);
    expect(segs.length, 4);
    expect(segs[3].discontinuity, isTrue);
    expect(hlsLeadingDiscontinuitySeconds(segs), closeTo(13.0, 0.001));
  });

  test('hlsFirstUriLine follows master then media URIs', () {
    expect(
      hlsFirstUriLine(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://cdn.example/a.m3u8\n',
      ),
      'https://cdn.example/a.m3u8',
    );
    expect(
      hlsFirstUriLine('#EXTM3U\n#EXTINF:4.0,\nseg0.ts\n'),
      'seg0.ts',
    );
  });

  test('fmp4BaseMediaTimeSeconds reads tfdt / mdhd', () {
    Uint8List u32(int v) => Uint8List.fromList([
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ]);
    Uint8List box(String type, Uint8List payload) {
      final size = 8 + payload.length;
      final out = Uint8List(size);
      out.setRange(0, 4, u32(size));
      out.setRange(4, 8, type.codeUnits);
      out.setRange(8, size, payload);
      return out;
    }

    final mdhd = Uint8List.fromList([
      0, 0, 0, 0, // version + flags
      0, 0, 0, 0, // creation
      0, 0, 0, 0, // modification
      ...u32(90000),
      0, 0, 0, 0, // duration
    ]);
    final tfdt = Uint8List.fromList([
      0, 0, 0, 0, // version + flags
      ...u32(1170000),
    ]);
    final init = box('moov', box('trak', box('mdia', box('mdhd', mdhd))));
    final frag = box('moof', box('traf', box('tfdt', tfdt)));
    expect(isoLooksLikeFmp4(init), isTrue);
    expect(fmp4BaseMediaTimeSeconds(init, frag), closeTo(13.0, 0.001));
  });

  test('hlsCdnSwapEncode replaces only the last 32-hex folder', () {
    const stream =
        'https://cdn.example/anime/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/index.m3u8';
    const vtt =
        'https://cdn.example/anime/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/'
        'cccccccccccccccccccccccccccccccc/subtitles/en.vtt';
    expect(hlsCdnEncodeId(stream), 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    expect(hlsCdnEncodeId(vtt), 'cccccccccccccccccccccccccccccccc');
    expect(
      hlsCdnSwapEncode(stream, 'cccccccccccccccccccccccccccccccc'),
      'https://cdn.example/anime/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/'
      'cccccccccccccccccccccccccccccccc/index.m3u8',
    );
  });

  test('hlsLeadingExtinfSkew finds extra segments at the start of the playing cut', () {
    final body = [3.0, 2.9, 3.0, 2.9, 3.5, 3.0, 3.0, 4.0, 2.5, 3.7, 3.7, 3.0];
    final playing = [4.0, 4.0, 4.0, ...body, 5.0, 5.0];
    expect(hlsLeadingExtinfSkew(playing, body), closeTo(12.0, 0.01));
    expect(hlsLeadingExtinfSkew(playing, playing), 0);
    expect(hlsLeadingExtinfSkew(body, body), 0);
    expect(hlsLeadingExtinfSkew([1, 1, 1, 1, 1, 1, 1, 1], body), isNull);
  });

  test('hlsExtinfFingerprint reports head, tail, and repeated EXTINF runs', () {
    final segs = [
      for (final d in [1.0, 2.0, 10.4, 10.4, 10.4, 10.4, 3.0])
        HlsMediaSegment(duration: d, uri: 'x', discontinuity: false),
    ];
    final fp = hlsExtinfFingerprint(segs);
    expect(fp, contains('n=7'));
    expect(fp, contains('repeat=4x10.400@3.0s'));
    expect(fp, contains('head=['));
    expect(fp, contains('tail=['));
  });

  test('hlsLeadingExtinfSkew treats extra duration at the tail as zero leading skew', () {
    final body = [4.037, 2.903, 3.036, 2.870, 2.569, 3.504, 2.970, 3.003, 4.004, 2.469, 3.737, 3.670];
    final playing = [...body, 9.0, 9.0, 4.346];
    expect(hlsLeadingExtinfSkew(playing, body), 0);
  });

  test('hlsPreferredVariantUri prefers matching basename over highest resolution', () {
    const master = '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=1280x720\n'
        'index-f2-v1-a1.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=854x480\n'
        'index-f1-v1-a1.m3u8\n';
    expect(
      hlsPreferredVariantUri(
        master,
        'https://cdn.example/enc/master.m3u8',
        preferBasename: 'index-f2-v1-a1.m3u8',
      ),
      'https://cdn.example/enc/index-f2-v1-a1.m3u8',
    );
    expect(
      hlsPreferredVariantUri(master, 'https://cdn.example/enc/master.m3u8'),
      'https://cdn.example/enc/index-f2-v1-a1.m3u8',
    );
  });

  test('hlsExtXMapUri and EXT-X-START parse from playlist text', () {
    const pl = '#EXTM3U\n'
        '#EXT-X-START:TIME-OFFSET=9.5\n'
        '#EXT-X-MAP:URI="init.mp4"\n'
        '#EXTINF:4.0,\n'
        'seg0.m4s\n';
    expect(hlsExtXMapUri(pl), 'init.mp4');
    expect(hlsExtXStartOffset(pl), 9.5);
  });
}
