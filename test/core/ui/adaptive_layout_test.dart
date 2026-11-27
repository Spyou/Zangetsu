import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/adaptive_layout.dart';
import 'package:watch_app/core/ui/poster_card.dart';

Future<T> _at<T>(
  WidgetTester tester,
  Size size,
  T Function(BuildContext) read,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late T out;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          out = read(context);
          return const SizedBox();
        },
      ),
    ),
  );
  return out;
}

void main() {
  const phone = Size(400, 800);
  const phoneLandscape = Size(800, 400);
  const tablet = Size(1280, 800);
  const tabletPortrait = Size(800, 1280);

  testWidgets('phones, even sideways, are never a tablet', (tester) async {
    expect(await _at(tester, phone, isTabletLayout), isFalse);
    expect(await _at(tester, phoneLandscape, isTabletLayout), isFalse);
    expect(await _at(tester, tablet, isTabletLayout), isTrue);
    expect(await _at(tester, tabletPortrait, isTabletLayout), isTrue);
  });

  testWidgets('tabletColumn hands a phone the very same widget', (
    tester,
  ) async {
    const child = SizedBox(key: Key('x'));
    expect(
      await _at(tester, phone, (c) => identical(tabletColumn(c, child), child)),
      isTrue,
    );
    expect(
      await _at(
        tester,
        tablet,
        (c) => identical(tabletColumn(c, child), child),
      ),
      isFalse,
    );
  });

  testWidgets('poster grid: phone keeps 3 columns, a tablet fits more', (
    tester,
  ) async {
    expect(await _at(tester, phone, posterGridColumns), 3);
    final wide = await _at(tester, tablet, posterGridColumns);
    expect(wide, greaterThan(3));
    expect(wide, lessThanOrEqualTo(9));
  });
}
