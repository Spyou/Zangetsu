import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:watch_app/features/player/engine/mpv_engine.dart';
import 'package:watch_app/features/player/engine/playback_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  test('MpvEngine exposes reactive state notifiers with sane defaults', () {
    final e = MpvEngine();
    addTearDown(e.dispose);
    expect(e.position.value, Duration.zero);
    expect(e.duration.value, Duration.zero);
    expect(e.playing.value, isFalse);
    expect(e.rate.value, 1.0);
    expect(e.audioTracks.value, isEmpty);
    expect(e.textTracks.value, isEmpty);
  });

  test('setRate updates the rate notifier', () async {
    final e = MpvEngine();
    addTearDown(e.dispose);
    await e.setRate(1.5);
    expect(e.rate.value, 1.5);
  });
}
