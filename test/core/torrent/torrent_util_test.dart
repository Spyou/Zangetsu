import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/torrent/torrent_util.dart';

void main() {
  test('detects magnet and .torrent, not direct urls', () {
    expect(isTorrentUrl('magnet:?xt=urn:btih:abc'), isTrue);
    expect(isTorrentUrl('https://x.com/file.torrent'), isTrue);
    expect(isTorrentUrl('https://x.com/video.mp4'), isFalse);
    expect(isTorrentUrl('https://x.com/master.m3u8'), isFalse);
  });
}
