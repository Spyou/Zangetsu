import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';

void main() {
  // Touch support: on a touchscreen TV a physical tap must trigger the same
  // action as the remote's OK. (Remote-only TVs never emit touch, so there's
  // nothing to assert there — this just proves the touch path is wired.)
  testWidgets('TvFocusable fires onTap on a physical touch tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TvFocusable(
              onTap: () => taps++,
              child: const SizedBox(width: 120, height: 120),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TvFocusable));
    await tester.pump();

    expect(taps, 1);
  });
}
