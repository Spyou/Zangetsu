import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/tv_exo_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TvExoController.applyEvent (event → state)', () {
    test('maps a full event map to the listenables', () {
      final c = TvExoController(0);
      c.applyEvent({
        'positionMs': 5000,
        'durationMs': 90000,
        'buffering': false,
        'playing': true,
        'ended': false,
      });
      expect(c.position.value, 5000);
      expect(c.duration.value, 90000);
      expect(c.playing.value, isTrue);
      expect(c.buffering.value, isFalse);
      expect(c.ended.value, isFalse);
      c.dispose();
    });

    test('missing/garbage fields fall back to safe defaults', () {
      final c = TvExoController(0);
      c.applyEvent({'positionMs': 'x', 'playing': null});
      expect(c.position.value, 0);
      expect(c.duration.value, 0);
      expect(c.playing.value, isFalse);
      c.dispose();
    });
  });

  group('TvExoController.shouldResumeSeek', () {
    test('seeks once when a resume point exists and duration is known', () {
      expect(
        TvExoController.shouldResumeSeek(
            resumeMs: 30000, durationMs: 90000, alreadySeeked: false),
        isTrue,
      );
    });
    test('does not re-seek once already seeked', () {
      expect(
        TvExoController.shouldResumeSeek(
            resumeMs: 30000, durationMs: 90000, alreadySeeked: true),
        isFalse,
      );
    });
    test('no seek when there is no resume point or duration unknown', () {
      expect(
        TvExoController.shouldResumeSeek(
            resumeMs: 0, durationMs: 90000, alreadySeeked: false),
        isFalse,
      );
      expect(
        TvExoController.shouldResumeSeek(
            resumeMs: 30000, durationMs: 0, alreadySeeked: false),
        isFalse,
      );
    });
    test('no seek when the resume point is at/after the end', () {
      expect(
        TvExoController.shouldResumeSeek(
            resumeMs: 90000, durationMs: 90000, alreadySeeked: false),
        isFalse,
      );
    });
  });
}
