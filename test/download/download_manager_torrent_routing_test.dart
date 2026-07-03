import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/models/video_source.dart';

void main() {
  test('isTorrentSource is true only for the torrent container', () {
    const torrent = VideoSource(
      url: 'magnet:?xt=urn:btih:abc',
      container: SourceContainer.torrent,
    );
    const hls = VideoSource(
      url: 'https://x/y.m3u8',
      container: SourceContainer.hls,
    );
    const mp4 = VideoSource(
      url: 'https://x/y.mp4',
      container: SourceContainer.mp4,
    );

    expect(DownloadManager.isTorrentSource(torrent), true);
    expect(DownloadManager.isTorrentSource(hls), false);
    expect(DownloadManager.isTorrentSource(mp4), false);
  });
}
