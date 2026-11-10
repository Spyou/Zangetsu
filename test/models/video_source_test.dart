import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';

void main() {
  test('adding subtitle tracks preserves playback and DRM fields', () {
    const source = VideoSource(
      url: 'magnet:?xt=urn:btih:test',
      label: 'Chosen',
      quality: '1080p',
      container: SourceContainer.torrent,
      torrentFileIndex: 2,
      drmKid: 'kid',
      drmKey: 'key',
      proxyUrl: 'https://proxy.test',
      headers: {'Referer': 'https://site.test'},
      audioLang: 'eng',
      kind: AudioKind.dub,
      subtitleSkewSeconds: 2,
      subtitleSkewAfterSeconds: 3,
    );
    const track = Subtitle(url: 'https://sub.test/en.srt', lang: 'eng');
    final result = source.withSubtitles([track]);
    expect(result.toJson(), {
      ...source.toJson(),
      'subtitles': [track.toJson()],
    });
    expect(result.torrentFileIndex, 2);
    expect(result.drmKid, 'kid');
    expect(result.drmKey, 'key');
    expect(result.proxyUrl, source.proxyUrl);
  });

  test(
    'subtitle provider names survive saving without changing legacy JSON',
    () {
      const subtitle = Subtitle(
        url: 'https://subs/en.srt',
        lang: 'en',
        label: 'English',
        providerName: 'Subtitle Addon',
      );
      final restored = Subtitle.fromJson(subtitle.toJson());
      expect(restored.providerName, 'Subtitle Addon');
      expect(restored.displayLabel, 'English · Subtitle Addon');
      const legacy = Subtitle(url: 'https://subs/en.srt', lang: 'en');
      expect(legacy.toJson(), isNot(contains('providerName')));
      expect(Subtitle.fromJson(legacy.toJson()).displayLabel, 'en');
    },
  );

  test('VideoSource parses an HLS sub source with soft subtitles', () {
    final src = VideoSource.fromJson({
      'url': 'https://cdn.test/master.m3u8',
      'quality': '1080p',
      'container': 'hls',
      'headers': {'Referer': 'https://embed.test/'},
      'kind': 'sub',
      'audioLang': 'ja',
      'subtitles': [
        {
          'url': 'https://cdn.test/en.vtt',
          'lang': 'en',
          'label': 'English',
          'format': 'vtt',
          'default': true,
        },
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
