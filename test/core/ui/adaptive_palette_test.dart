import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/adaptive_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('redistributed quantizer notices are bundled', () async {
    final text = await rootBundle.loadString(
      'assets/licenses/adaptive_palette.txt',
    );
    expect(text, contains('Copyright 2018 The Android Open Source Project'));
    expect(text, contains('Copyright (c) 2023 Jordon de Hoog'));
    expect(text, contains('Apache License'));
    expect(text, contains('MIT License'));
  });

  test('empty and neutral thumbnails have no adaptive tint', () {
    expect(adaptiveDominantColor(Uint8List(0)), isNull);
    expect(
      adaptiveDominantColor(
        Uint8List.fromList([
          0,
          0,
          0,
          255,
          255,
          255,
          255,
          255,
          128,
          128,
          128,
          255,
        ]),
      ),
      isNull,
    );
  });

  test('malformed RGBA data is rejected', () {
    expect(() => adaptiveDominantColor(Uint8List(3)), throwsArgumentError);
  });

  test('equal populations preserve source swatch order', () {
    expect(
      adaptiveDominantColor(
        Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]),
      ),
      const Color(0xFF0000F8),
    );
  });

  test('black pixels do not hide the remaining chromatic swatch', () {
    expect(
      adaptiveDominantColor(
        Uint8List.fromList([0, 0, 0, 255, 0, 0, 0, 255, 255, 0, 0, 255]),
      ),
      const Color(0xFFF80000),
    );
  });

  test('source precision is retained at hue filter boundaries', () {
    expect(
      adaptiveDominantColor(Uint8List.fromList([128, 88, 80, 255])),
      const Color(0xFF805850),
    );
  });
}
