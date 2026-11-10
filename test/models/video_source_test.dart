import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';

void main() {
  test('VideoSource parses an HLS sub source with soft subtitles', () {
    final src = VideoSource.fromJson({
      'url': 'https://cdn.test/master.m3u8',
      'quality': '1080p',
      'container': 'hls',
      'headers': {'Referer': 'https://embed.test/'},
      'kind': 'sub',
      'audioLang': 'ja',
      'subtitles': [
        {'url': 'https://cdn.test/en.vtt', 'lang': 'en', 'label': 'English',
         'format': 'vtt', 'default': true},
      ],
    });
    expect(src.container, SourceContainer.hls);
    expect(src.kind, AudioKind.sub);
    expect(src.headers!['Referer'], 'https://embed.test/');
    expect(src.subtitles.single.isDefault, true);
    expect(src.subtitles.single.lang, 'en');
  });

  test('VideoSource defaults unknown enums and empty subtitles', () {
    final src = VideoSource.fromJson({'url': 'https://cdn.test/v.mp4'});
    expect(src.container, SourceContainer.unknown);
    expect(src.kind, AudioKind.unknown);
    expect(src.subtitles, isEmpty);
    expect(src.toJson()['url'], 'https://cdn.test/v.mp4');
  });
}
