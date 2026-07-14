// test/features/player/engine/engine_router_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/engine/engine_router.dart';
import 'package:watch_app/features/player/engine/playback_engine.dart';

EngineSource src({bool torrent = false, bool ass = false, String? mime}) =>
    EngineSource(
      url: 'http://x/v',
      isTorrent: torrent,
      hasAssSubtitles: ass,
      mimeType: mime,
    );

void main() {
  test('toggle off → always mpv', () {
    expect(EngineRouter.pick(source: src(), fastPlayer: false), EngineChoice.mpv);
    expect(EngineRouter.pick(source: src(torrent: true), fastPlayer: false),
        EngineChoice.mpv);
    expect(EngineRouter.pick(source: src(ass: true), fastPlayer: false),
        EngineChoice.mpv);
  });

  test('toggle on, normal stream → exo', () {
    expect(EngineRouter.pick(source: src(), fastPlayer: true), EngineChoice.exo);
    expect(
        EngineRouter.pick(
            source: src(mime: 'application/x-mpegURL'), fastPlayer: true),
        EngineChoice.exo);
  });

  test('toggle on, torrent → mpv', () {
    expect(EngineRouter.pick(source: src(torrent: true), fastPlayer: true),
        EngineChoice.mpv);
  });

  test('toggle on, ASS subs → mpv (richer subtitle rendering)', () {
    expect(EngineRouter.pick(source: src(ass: true), fastPlayer: true),
        EngineChoice.mpv);
  });

  test('shouldFallback: exo error before first frame → true', () {
    expect(shouldFallback(const EngineError(code: 'DECODER_INIT', framesRendered: false)),
        isTrue);
  });

  test('shouldFallback: error after frames rendered → true (audio codec died)', () {
    expect(shouldFallback(const EngineError(code: 'AUDIO_UNSUPPORTED', framesRendered: true)),
        isTrue);
  });
}
