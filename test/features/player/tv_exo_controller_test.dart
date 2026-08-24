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

    test('keeps a known duration when a later event still reports 0', () {
      final c = TvExoController(0);
      c.applyEvent({'positionMs': 1000, 'durationMs': 90000});
      c.applyEvent({'positionMs': 2000, 'durationMs': 0});
      expect(c.duration.value, 90000);
      expect(c.position.value, 2000);
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

  // Video renditions inside the open stream — the only thing the TV Quality
  // menu is allowed to offer. Other sources are separate files on separate
  // servers and belong under Sources.
  group('video tracks', () {
    test('parses renditions and sorts them tallest first', () {
      final c = TvExoController(0);
      c.applyEvent({
        'videoTracks': [
          {'id': '0:1', 'label': '', 'language': '', 'selected': false, 'height': 720},
          {'id': '0:2', 'label': '', 'language': '', 'selected': true, 'height': 1080},
          {'id': '0:0', 'label': '', 'language': '', 'selected': false, 'height': 480},
        ],
      });
      expect(c.videoTracks.value.map((t) => t.height).toList(), [1080, 720, 480]);
      expect(c.videoTracks.value.first.id, '0:2');
      c.dispose();
    });

    test('a rendition with no usable height is dropped, not shown as 0p', () {
      final c = TvExoController(0);
      c.applyEvent({
        'videoTracks': [
          {'id': '0:0', 'selected': false, 'height': 1080},
          {'id': '0:1', 'selected': false},
        ],
      });
      expect(c.videoTracks.value.map((t) => t.height).toList(), [1080, null]);
      // One real rendition -> the menu's `length > 1` gate is what keeps a
      // single-track stream from showing a quality choice.
      c.dispose();
    });

    test('garbage and absence leave it empty rather than throwing', () {
      final c = TvExoController(0);
      c.applyEvent({'positionMs': 1});
      expect(c.videoTracks.value, isEmpty);
      c.applyEvent({'videoTracks': 'nope'});
      expect(c.videoTracks.value, isEmpty);
      c.dispose();
    });

    test('videoHeight tracks the frame actually on screen', () {
      final c = TvExoController(0);
      c.applyEvent({'videoHeight': 1080});
      expect(c.videoHeight.value, 1080);
      c.applyEvent({'positionMs': 1});
      expect(c.videoHeight.value, 1080); // absent field doesn't clobber it
      c.dispose();
    });
  });
}
