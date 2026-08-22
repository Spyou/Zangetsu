import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/skip_service.dart';

SkipInterval _iv(int startS, int endS, String type) => SkipInterval(
  start: Duration(seconds: startS),
  end: Duration(seconds: endS),
  type: type,
);

void main() {
  final op = _iv(60, 150, 'op');
  final ed = _iv(1300, 1390, 'ed');
  final skips = [op, ed];

  final recap = _iv(0, 42, 'recap');

  group('isRecapSkip', () {
    test('recap is its own category, not an opening', () {
      expect(isRecapSkip('recap'), isTrue);
      expect(isRecapSkip('op'), isFalse);
      expect(isRecapSkip('ed'), isFalse);
      // The trap this exists for: 'recap' does not end in 'ed', so the
      // ending check sends it to the OPENING toggle unless recap is tested
      // first.
      expect(isEndingSkip('recap'), isFalse);
    });
  });

  group('skipLabel', () {
    test('names each type for the button', () {
      expect(skipLabel('recap'), 'Skip Recap');
      expect(skipLabel('ed'), 'Skip Ending');
      expect(skipLabel('mixed-ed'), 'Skip Ending');
      expect(skipLabel('op'), 'Skip Opening');
      expect(skipLabel('mixed-op'), 'Skip Opening');
    });
  });

  group('recap routing', () {
    final withRecap = [recap, op, ed];

    test('the opening toggle must NOT skip a recap', () {
      expect(
        autoSkipAt(withRecap, const Duration(seconds: 10),
            op: true, ed: true, recap: false, fired: {}),
        isNull,
        reason: 'recap riding on the OP toggle is the bug this guards',
      );
    });

    test('its own toggle skips it', () {
      expect(
        autoSkipAt(withRecap, const Duration(seconds: 10),
            op: false, ed: false, recap: true, fired: {}),
        same(recap),
      );
    });

    test('turning recap on leaves the opening alone', () {
      expect(
        autoSkipAt(withRecap, const Duration(seconds: 70),
            op: false, ed: false, recap: true, fired: {}),
        isNull,
      );
    });

    test('a recap starting at 0:00 still fires (Jujutsu Kaisen ep 3)', () {
      expect(
        autoSkipAt(withRecap, Duration.zero,
            op: false, ed: false, recap: true, fired: {}),
        same(recap),
      );
    });
  });

  group('isEndingSkip', () {
    test('routes AniSkip types to the right toggle', () {
      expect(isEndingSkip('op'), isFalse);
      expect(isEndingSkip('ed'), isTrue);
      expect(isEndingSkip('mixed-ed'), isTrue);
      // "mixed" itself contains "ed", so a contains() check would wrongly send
      // a mixed opening to the ending toggle.
      expect(isEndingSkip('mixed-op'), isFalse);
      expect(isEndingSkip('recap'), isFalse);
    });
  });

  group('autoSkipAt', () {
    test('fires inside the opening when the OP toggle is on', () {
      final iv = autoSkipAt(
        skips,
        const Duration(seconds: 70),
        op: true,
        ed: false,
        recap: false,
        fired: {},
      );
      expect(iv, same(op));
    });

    test('stays quiet outside every interval', () {
      expect(
        autoSkipAt(skips, const Duration(seconds: 400),
            op: true, ed: true, recap: false, fired: {}),
        isNull,
      );
    });

    test('honours each toggle independently', () {
      // Sitting in the ending with only the OP toggle on.
      expect(
        autoSkipAt(skips, const Duration(seconds: 1320),
            op: true, ed: false, recap: false, fired: {}),
        isNull,
      );
      expect(
        autoSkipAt(skips, const Duration(seconds: 1320),
            op: false, ed: true, recap: false, fired: {}),
        same(ed),
      );
    });

    test('fires once per interval — seeking back in does not bounce you out',
        () {
      final fired = <int>{};
      final first = autoSkipAt(skips, const Duration(seconds: 70),
          op: true, ed: true, recap: false, fired: fired);
      expect(first, same(op));
      fired.add(first!.start.inMilliseconds);

      // User deliberately seeks back into the opening to watch it.
      expect(
        autoSkipAt(skips, const Duration(seconds: 70),
            op: true, ed: true, recap: false, fired: fired),
        isNull,
      );
      // The ending is a different interval and still fires.
      expect(
        autoSkipAt(skips, const Duration(seconds: 1320),
            op: true, ed: true, recap: false, fired: fired),
        same(ed),
      );
    });

    test('leaves the last second alone', () {
      // 149s is inside [60,150) but within the 1s tail guard.
      expect(
        autoSkipAt(skips, const Duration(seconds: 149),
            op: true, ed: true, recap: false, fired: {}),
        isNull,
      );
      expect(
        autoSkipAt(skips, const Duration(seconds: 148),
            op: true, ed: true, recap: false, fired: {}),
        same(op),
      );
    });

    test('start is inclusive, end is exclusive', () {
      expect(
        autoSkipAt(skips, const Duration(seconds: 60),
            op: true, ed: true, recap: false, fired: {}),
        same(op),
      );
      expect(
        autoSkipAt(skips, const Duration(seconds: 150),
            op: true, ed: true, recap: false, fired: {}),
        isNull,
      );
    });
  });
}
