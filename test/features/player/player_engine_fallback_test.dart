import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/models/video_source.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
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

  test('DRM never switches engines', () {
    for (final engine in PlaybackEngine.values) {
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

  test('torrents only move native toward mpv, never the reverse', () {
    const torrent = VideoSource(url: 'magnet:?xt=urn:btih:abc');
    // Native can't open magnets — may yield to mpv once.
    expect(fail(PlaybackEngine.nativePlayer, source: torrent), PlaybackEngine.mpv);
    // mpv plays torrents itself; bouncing one to native is an instant loop.
    expect(fail(PlaybackEngine.mpv, source: torrent), isNull);
    expect(fallback.blockedUrls('episode-1', 'sub'), isEmpty);
  });

  test('phone route never sends the native choice down the external path', () {
    const torrent = VideoSource(url: 'magnet:?xt=urn:btih:abc');
    const http = VideoSource(url: 'https://cdn.test/video');
    // Native choice, no seed yet (episode flow resolves later) → native.
    expect(
      resolvePhonePlayerRoute(
        isAndroid: true,
        chosenPlayer: PlaybackPrefs.androidPlayerId,
      ),
      PhonePlayerRoute.exo,
    );
    // Native choice, playable seed → native.
    expect(
      resolvePhonePlayerRoute(
        isAndroid: true,
        chosenPlayer: PlaybackPrefs.androidPlayerId,
        initialSource: http,
      ),
      PhonePlayerRoute.exo,
    );
    // Native choice, torrent seed → in-app mpv (never external, never native).
    expect(
      resolvePhonePlayerRoute(
        isAndroid: true,
        chosenPlayer: PlaybackPrefs.androidPlayerId,
        initialSource: torrent,
      ),
      PhonePlayerRoute.inApp,
    );
    // Real external package → external; unset choice → in-app; iOS → in-app.
    expect(
      resolvePhonePlayerRoute(isAndroid: true, chosenPlayer: 'org.videolan.vlc'),
      PhonePlayerRoute.external,
    );
    expect(
      resolvePhonePlayerRoute(isAndroid: true, chosenPlayer: ''),
      PhonePlayerRoute.inApp,
    );
    expect(
      resolvePhonePlayerRoute(
        isAndroid: false,
        chosenPlayer: PlaybackPrefs.androidPlayerId,
      ),
      PhonePlayerRoute.inApp,
    );
  });
}
