import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/download_record.dart';

void main() {
  test('public sidecar path survives download-record persistence', () {
    final restored = OfflineSubtitle.fromMap({
      'lang': 'en',
      'path': '/private/subs/episode.en.vtt',
      'publicPath': '/storage/Download/AniAura/Show/episode.en.srt',
    });

    expect(
      restored.toMap()['publicPath'],
      '/storage/Download/AniAura/Show/episode.en.srt',
    );
  });

  test('older records without a public sidecar remain readable', () {
    final restored = OfflineSubtitle.fromMap({
      'lang': 'en',
      'path': '/private/subs/episode.en.vtt',
    });

    expect(restored.toMap()['publicPath'], isNull);
  });
}
