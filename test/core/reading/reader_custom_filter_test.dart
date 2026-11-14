import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/reading/reader_settings.dart';

void main() {
  group('readerCustomBlendMode', () {
    test('maps the Mihon set', () {
      expect(readerCustomBlendMode('default'), BlendMode.srcOver);
      expect(readerCustomBlendMode('multiply'), BlendMode.multiply);
      expect(readerCustomBlendMode('screen'), BlendMode.screen);
      expect(readerCustomBlendMode('overlay'), BlendMode.overlay);
      expect(readerCustomBlendMode('dodge'), BlendMode.colorDodge);
      expect(readerCustomBlendMode('lighten'), BlendMode.lighten);
    });

    test('unknown keys fall back to a plain overlay', () {
      expect(readerCustomBlendMode('bogus'), BlendMode.srcOver);
    });

    test('custom tint builds a mode filter', () {
      const filter = ColorFilter.mode(
        Color(0xFFFFBA55),
        BlendMode.multiply,
      );
      expect(filter, isA<ColorFilter>());
    });
  });
}
