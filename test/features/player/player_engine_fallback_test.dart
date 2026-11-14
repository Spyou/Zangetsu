import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/features/player/player_engine_fallback.dart';

void main() {
  late PlayerEngineFallback fallback;
  setUp(() => fallback = PlayerEngineFallback());

  PlaybackEngine? fail(
    PlaybackEngine engine, {
    bool enabled = true,
    String episode = 'episode-1',
    String category = 'sub',
    VideoSource source = const VideoSource(url: 'https://cdn.test/video'),
  }) => fallback.next(
    enabled: enabled,
    failedEngine: engine,
    episodeUrl: episode,
    category: category,
    source: source,
  );

  test('off leaves both players and mirror ordering alone', () {
    expect(fail(PlaybackEngine.mpv, enabled: false), isNull);
    expect(fallback.blockedUrls('episode-1', 'sub'), isEmpty);
    expect(fail(PlaybackEngine.mpv), PlaybackEngine.nativePlayer);
  });

  for (final engine in PlaybackEngine.values) {
    test(
      '$engine tries the other engine once, then allows the next mirror',
      () {
        final other = PlaybackEngine.values.firstWhere((e) => e != engine);
        expect(fail(engine), other);
        expect(fail(engine), isNull);
        expect(fallback.blockedUrls('episode-1', 'sub'), isEmpty);
        expect(fail(other), isNull);
        expect(fallback.blockedUrls('episode-1', 'sub'), {
          'https://cdn.test/video',
        });
        expect(fail(engine), isNull);
        expect(fail(other), isNull);
        expect(
          fail(
            other,
            source: const VideoSource(url: 'https://cdn.test/second'),
          ),
          engine,
        );
      },
    );
  }

  test('a new episode or Sub/Dub choice gets a fresh attempt', () {
    expect(fail(PlaybackEngine.mpv), PlaybackEngine.nativePlayer);
    expect(fail(PlaybackEngine.nativePlayer), isNull);
    expect(fallback.blockedUrls('episode-2', 'sub'), isEmpty);
    expect(
      fail(PlaybackEngine.mpv, episode: 'episode-2'),
      PlaybackEngine.nativePlayer,
    );
    expect(
      fail(PlaybackEngine.mpv, episode: 'episode-2', category: 'dub'),
      PlaybackEngine.nativePlayer,
    );
  });

  test('DRM and torrents never switch engines', () {
    for (final engine in PlaybackEngine.values) {
      expect(
        fail(engine, source: const VideoSource(url: 'magnet:?xt=urn:btih:abc')),
        isNull,
      );
      expect(
        fail(
          engine,
          source: const VideoSource(
            url: 'https://cdn.test/video',
            drmKid: 'id',
            drmKey: 'key',
          ),
        ),
        isNull,
      );
    }
    expect(fallback.blockedUrls('episode-1', 'sub'), isEmpty);
  });
}
