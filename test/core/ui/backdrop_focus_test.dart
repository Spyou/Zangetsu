import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/backdrop_focus.dart';

/// A dark wide frame with one bright, busy block at columns [from, to).
Uint8List _frame(int w, int h, {required int from, required int to}) {
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final inBlock = x >= from && x < to && y > h ~/ 5 && y < h * 3 ~/ 4;
      final v = inBlock ? ((x + y) % 2 == 0 ? 230 : 40) : 20;
      px[i] = v;
      px[i + 1] = v;
      px[i + 2] = v;
      px[i + 3] = 255;
    }
  }
  return px;
}

void main() {
  test('subject on the left pulls the crop left', () {
    final cols = analyzeColumns(_frame(96, 54, from: 4, to: 24), 96, 54);
    expect(horizontalBias(cols, 0.4), lessThan(-0.3));
  });

  test('subject on the right pulls the crop right', () {
    final cols = analyzeColumns(_frame(96, 54, from: 72, to: 92), 96, 54);
    expect(horizontalBias(cols, 0.4), greaterThan(0.3));
  });

  test('subject in the middle stays centred', () {
    final cols = analyzeColumns(_frame(96, 54, from: 38, to: 58), 96, 54);
    expect(horizontalBias(cols, 0.4), 0);
  });

  test('a flat image has no preference', () {
    final cols = analyzeColumns(_frame(96, 54, from: 0, to: 0), 96, 54);
    expect(horizontalBias(cols, 0.4), 0);
  });

  test('nothing is cropped when the whole width shows', () {
    final cols = analyzeColumns(_frame(96, 54, from: 4, to: 24), 96, 54);
    expect(horizontalBias(cols, 1), 0);
    expect(horizontalBias(cols, 0.98), 0);
  });

  test('BackdropFocus only reacts when the image is wider than the box', () {
    final cols = analyzeColumns(_frame(96, 54, from: 4, to: 24), 96, 54);
    final focus = BackdropFocus(cols, 16 / 9);
    expect(focus.biasFor(0.73), lessThan(-0.3)); // tall box, wide image
    expect(focus.biasFor(2.0), 0); // box wider than the image
  });

  test('too small or empty input gives no columns', () {
    expect(analyzeColumns(Uint8List(0), 0, 0), isEmpty);
    expect(analyzeColumns(Uint8List(16), 2, 2), isEmpty);
  });

  testWidgets('works end to end on a real image, through the isolate', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // A dark 16:9 picture with one bright, busy block near the left edge.
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 320, 180),
        ui.Paint()..color = const ui.Color(0xFF141414),
      );
      for (var y = 40; y < 140; y += 8) {
        for (var x = 20; x < 100; x += 8) {
          canvas.drawRect(
            ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 8, 8),
            ui.Paint()
              ..color = ((x + y) ~/ 8).isEven
                  ? const ui.Color(0xFFEBEBEB)
                  : const ui.Color(0xFF282828),
          );
        }
      }
      final image = await recorder.endRecording().toImage(320, 180);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final provider = MemoryImage(png.buffer.asUint8List());

      final focus = await backdropFocusFor(provider, key: 'e2e-left');
      expect(focus, isNotNull);
      expect(focus!.aspect, closeTo(16 / 9, 0.05));
      expect(focus.biasFor(0.73), lessThan(-0.3));
      // Asked again, it is answered from the cache without loading anything.
      expect(backdropFocusCached('e2e-left'), isNotNull);
    });
  });

  testWidgets('a picture that cannot be read gives no focus, and is not retried '
      'at once', (tester) async {
    await tester.runAsync(() async {
      final bad = MemoryImage(Uint8List.fromList([1, 2, 3]));
      expect(await backdropFocusFor(bad, key: 'e2e-bad'), isNull);
      expect(backdropFocusCached('e2e-bad'), isNull);
      // Second ask returns at once (remembered miss) instead of loading again.
      expect(await backdropFocusFor(bad, key: 'e2e-bad'), isNull);
    });
  });
}
