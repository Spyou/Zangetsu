import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';
import 'package:watch_app/features/reader/novel_reader_screen.dart';

/// Stands in for ReaderPrefs so these can run without Hive.
class _Prefs implements ReaderPrefs {
  _Prefs(this._direction);
  final String _direction;

  @override
  String get textDirection => _direction;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('only textDirection is used here');
}

void main() {
  group('resolveNovelDirection', () {
    test('an explicit choice wins over what the text looks like', () {
      const arabic = '<p>مرحبا بالعالم وهذا فصل كامل من الرواية</p>';
      expect(resolveNovelDirection(_Prefs('ltr'), arabic), TextDirection.ltr);
      expect(
        resolveNovelDirection(_Prefs('rtl'), '<p>Plain English.</p>'),
        TextDirection.rtl,
      );
    });

    test('auto flips for an Arabic chapter and leaves English alone', () {
      expect(
        resolveNovelDirection(
          _Prefs('auto'),
          '<p>مرحبا بالعالم وهذا فصل كامل من الرواية العربية</p>',
        ),
        TextDirection.rtl,
      );
      expect(
        resolveNovelDirection(
          _Prefs('auto'),
          '<p>He turned the page and kept reading.</p>',
        ),
        TextDirection.ltr,
      );
    });

    test('a stray Arabic name in a Latin chapter stays left-to-right', () {
      // The ratio is what buys this: matching on "any RTL character" would
      // flip an English chapter the moment someone is named in Arabic.
      const mixed =
          '<p>She introduced herself as مريم and the rest of the evening '
          'passed quietly, the way most evenings did in that town.</p>';
      expect(resolveNovelDirection(_Prefs('auto'), mixed), TextDirection.ltr);
    });

    test('a chapter shorter than the sample window does not throw', () {
      // Regression: the sampler sliced the tag-stripped text to the *html's*
      // length. Tags collapse to one space each, so the bound overran the end
      // and every short chapter threw a RangeError on open.
      expect(
        resolveNovelDirection(_Prefs('auto'), '<p>Short chapter.</p>'),
        TextDirection.ltr,
      );
      expect(resolveNovelDirection(_Prefs('auto'), ''), TextDirection.ltr);
      expect(
        resolveNovelDirection(_Prefs('auto'), '<p></p><div></div>'),
        TextDirection.ltr,
      );
    });
  });
}
