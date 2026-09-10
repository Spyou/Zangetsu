import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_manager.dart';
import 'package:watch_app/core/models/video_source.dart';

VideoSource _src(String url, {SourceContainer c = SourceContainer.unknown}) =>
    VideoSource(url: url, container: c);

void main() {
  test('a DASH manifest is not a downloadable source', () {
    // It is a few KB of XML pointing at the video, so downloading it "succeeds"
    // and leaves a file that is not an episode. The size guard used to be the
    // only thing that noticed — after a request, a write and a delete.
    expect(DownloadManager.isDash(_src('https://x.com/v/master.mpd')), isTrue);
    expect(
      DownloadManager.isDash(_src('https://x.com/v/master.mpd?token=abc')),
      isTrue,
      reason: 'a query string must not hide the extension',
    );
  });

  test('real sources are not mistaken for DASH', () {
    for (final u in const [
      'https://x.com/v/ep1.mp4',
      'https://x.com/v/index.m3u8',
      'https://x.com/v/mpd-player/ep1.mp4', // "mpd" in the path, not the ext
      'magnet:?xt=urn:btih:abc',
    ]) {
      expect(DownloadManager.isDash(_src(u)), isFalse, reason: u);
    }
  });
}
