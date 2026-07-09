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

  group('TvExoController.applyEvent (tracks)', () {
    test('parses audio/text track lists', () {
      final c = TvExoController(9001);
      c.applyEvent({
        'positionMs': 0,
        'durationMs': 0,
        'audioTracks': [
          {'id': '0:0', 'language': 'jpn', 'label': 'Japanese', 'selected': true},
          {'id': '0:1', 'language': 'eng', 'label': '', 'selected': false},
        ],
        'textTracks': [
          {'id': '1:0', 'language': 'en', 'label': 'English', 'selected': false},
        ],
      });
      expect(c.audioTracks.value.length, 2);
      expect(c.audioTracks.value.first.language, 'jpn');
      expect(c.audioTracks.value.first.selected, isTrue);
      expect(c.audioTracks.value[1].label, isNull); // empty -> null
      expect(c.textTracks.value.single.id, '1:0');
      c.dispose();
    });

    test('missing/garbage track fields fall back to empty lists', () {
      final c = TvExoController(9002);
      c.applyEvent({'positionMs': 0, 'durationMs': 0}); // no track keys
      expect(c.audioTracks.value, isEmpty);
      c.applyEvent({'audioTracks': 'nope', 'textTracks': 42});
      expect(c.audioTracks.value, isEmpty);
      expect(c.textTracks.value, isEmpty);
      c.dispose();
    });

    test('unchanged list does not create a new notifier value', () {
      final c = TvExoController(9003);
      const payload = {
        'audioTracks': [
          {'id': '0:0', 'language': 'jpn', 'label': 'Japanese', 'selected': true},
        ],
      };
      c.applyEvent(Map<String, dynamic>.from(payload));
      final first = c.audioTracks.value;
      c.applyEvent(Map<String, dynamic>.from(payload));
      expect(identical(c.audioTracks.value, first), isTrue); // no churn
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
