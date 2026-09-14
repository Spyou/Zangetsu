import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/featured_carousel.dart';

/// The hero used to be a flat 540px. That is fine on a tall phone and far too
/// much on a short one, where it swallowed the screen and the dock landed on
/// the page dots.
Future<double> heightOn(WidgetTester tester, double screenHeight) async {
  late double got;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: Size(400, screenHeight)),
      child: Builder(
        builder: (context) {
          got = heroHeightFor(context);
          return const SizedBox();
        },
      ),
    ),
  );
  return got;
}

void main() {
  testWidgets('a tall phone keeps the height the design was tuned at', (
    tester,
  ) async {
    // 1080x2400 @ 440dpi — the phone the 540 was eyeballed on.
    expect(await heightOn(tester, 872.7), closeTo(541, 1));
  });

  testWidgets('a short phone gets a proportionally shorter hero', (
    tester,
  ) async {
    // 1080x1920 @ 480dpi. The old 540 was 84% of this screen.
    final h = await heightOn(tester, 640);
    expect(h, closeTo(397, 1));
    expect(h / 640, lessThan(0.65), reason: 'must not swallow the screen');
  });

  testWidgets('very short screens stop at the floor', (tester) async {
    // Below the floor the content block (~230dp) would crowd the artwork.
    expect(await heightOn(tester, 500), kHeroHeightMin);
  });

  testWidgets('tablets stop at the ceiling', (tester) async {
    expect(await heightOn(tester, 1400), kHeroHeightMax);
  });
}
