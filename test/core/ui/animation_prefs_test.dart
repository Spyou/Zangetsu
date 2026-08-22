import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/animation_prefs.dart';

void main() {
  group('list animation style', () {
    test('defaults to rise', () {
      expect(AnimationPrefs.style, ListAnimStyle.rise);
    });

    test('an absent or unknown stored name falls back to the default', () {
      // An older install has nothing stored; a newer build could write a name
      // this one has never heard of. Neither should throw or blank the list.
      expect(AnimationPrefs.styleFromNameForTest(null), ListAnimStyle.rise);
      expect(AnimationPrefs.styleFromNameForTest('somethingNew'),
          ListAnimStyle.rise);
    });

    test('known names round-trip', () {
      for (final s in ListAnimStyle.values) {
        expect(AnimationPrefs.styleFromNameForTest(s.name), s);
      }
    });
  });
}
