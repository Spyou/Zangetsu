import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/stremio/stremio_link_session.dart';
import 'package:watch_app/core/stremio/stremio_ref.dart';
import 'package:watch_app/core/stremio/stremio_stream_mapping.dart';
import 'package:zangetsu_source_bridge/stremio.dart';

const _ref = StremioRef(
  installationId: 'addon-a',
  type: 'series',
  itemId: 'tt1',
  videoId: 'tt1:1:1',
);

StremioLinkChoice _choice(StremioStream stream) => StremioLinkChoice(
  installationId: 'addon-a',
  ref: _ref,
  stream: stream,
  label: stremioStreamLabel(stream),
);

void main() {
  test(
    'Stremio torrents use the built-in engine without changing other player preferences',
    () {
      const torrent = VideoSource(
        url: 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567',
      );
      const direct = VideoSource(url: 'https://cdn.example/video.m3u8');
      expect(stremioPlayerPackage('stremio', torrent, 'native'), '');
      expect(stremioPlayerPackage('stremio', direct, 'native'), 'native');
      expect(stremioPlayerPackage('cs:test', torrent, 'native'), 'native');
      expect(stremioPlayerPackage('stremio', null, 'external'), 'external');
      expect(stremioSeedSources('stremio', direct), [direct]);
      expect(stremioSeedSources('cs:test', direct), isNull);
    },
  );

  test('direct streams keep exact headers, quality and container', () {
    final choice = _choice(
      const StremioStream(
        kind: StremioStreamKind.direct,
        url: 'https://cdn.example/video.m3u8',
        name: '4K',
        description: 'WEB-DL · 12GB',
        headers: {'Referer': 'https://ref/', 'User-Agent': 'UA'},
        fileName: 'movie.mkv',
      ),
    );

    final source = stremioVideoSource(choice)!;
    expect(source.url, 'https://cdn.example/video.m3u8');
    expect(source.headers, {'Referer': 'https://ref/', 'User-Agent': 'UA'});
    expect(source.quality, '4k');
    expect(source.label, '4K · WEB-DL · 12GB');
    expect(source.container, SourceContainer.hls);
    expect(source.kind, AudioKind.unknown);
  });

  test('inline and requested subtitles merge without duplicates', () {
    final choice = _choice(
      const StremioStream(
        kind: StremioStreamKind.direct,
        url: 'https://cdn.example/video.mp4',
        subtitles: [
          StremioSubtitle(
            url: 'https://subs.example/inline.srt',
            lang: 'Inline',
          ),
          StremioSubtitle(url: 'https://subs.example/en.srt', lang: 'English'),
        ],
      ),
    );
    final source = stremioVideoSource(
      choice,
      streamAddonName: 'Video Addon',
      extraSubtitles: const [
        Subtitle(
          url: 'https://subs.example/en.srt',
          lang: 'English',
          format: 'srt',
        ),
        Subtitle(
          url: 'https://subs.example/hi.vtt',
          lang: 'Hindi',
          format: 'vtt',
          providerName: 'Subtitle Addon',
        ),
      ],
    )!;
    expect(source.container, SourceContainer.mp4);
    expect(source.subtitles.map((s) => s.url), [
      'https://subs.example/inline.srt',
      'https://subs.example/en.srt',
      'https://subs.example/hi.vtt',
    ]);
    expect(source.subtitles.last.format, 'vtt');
    expect(source.subtitles.last.lang, 'Hindi');
    expect(source.subtitles.first.providerName, 'Video Addon');
    expect(source.subtitles.last.providerName, 'Subtitle Addon');
  });

  test('non-direct link kinds are never a VideoSource', () {
    for (final kind in [
      StremioStreamKind.torrent,
      StremioStreamKind.youtube,
      StremioStreamKind.external,
      StremioStreamKind.unsupported,
    ]) {
      final choice = _choice(StremioStream(kind: kind, url: 'https://x'));
      expect(stremioVideoSource(choice), isNull);
    }
  });

  test('container helpers only claim known files', () {
    expect(stremioStreamContainer('https://x/a.m3u8'), SourceContainer.hls);
    expect(stremioStreamContainer('https://x/a.MP4'), SourceContainer.mp4);
    expect(stremioStreamContainer('https://x/live'), SourceContainer.unknown);
    expect(stremioStreamQuality('1080p WEB-DL'), '1080p');
    expect(stremioStreamQuality('nothing'), isNull);
  });
}
