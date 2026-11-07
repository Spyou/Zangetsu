import 'package:cue/cue.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/watch_page_motion.dart';

Widget fixture(Widget child, {bool landscape = false, bool reduced = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: landscape ? const Size(900, 400) : const Size(400, 900),
          disableAnimations: reduced,
        ),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  testWidgets('press feedback never delays the existing episode callback', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      fixture(
        WatchPagePress(
          child: GestureDetector(
            onTap: () => opened++,
            child: const SizedBox(
              width: 100,
              height: 60,
              child: Text('Episode'),
            ),
          ),
        ),
      ),
    );
    final press = await tester.startGesture(
      tester.getCenter(find.text('Episode')),
    );
    await tester.pump(const Duration(milliseconds: 40));
    expect(opened, 0);
    await press.up();
    expect(opened, 1);
    await tester.pumpAndSettle();
  });
  testWidgets(
    'rapid text changes remain immediate and can be disposed mid-animation',
    (tester) async {
      final value = ValueNotifier(0);
      addTearDown(value.dispose);
      await tester.pumpWidget(
        fixture(
          ValueListenableBuilder<int>(
            valueListenable: value,
            builder: (_, value, _) =>
                WatchPageChange(value: value, child: Text('Episode $value')),
          ),
        ),
      );
      value.value = 1;
      await tester.pump();
      expect(find.text('Episode 1'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 40));
      value.value = 2;
      await tester.pump();
      expect(find.text('Episode 2'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final landscape in [false, true]) {
    testWidgets(
      'motion is absent for ${landscape ? 'landscape' : 'reduced motion'}',
      (tester) async {
        await tester.pumpWidget(
          fixture(
            const WatchPagePress(
              child: WatchPageChange(
                value: 1,
                child: WatchPageMenuEntrance(child: Text('Content')),
              ),
            ),
            landscape: landscape,
            reduced: !landscape,
          ),
        );
        expect(find.byWidgetPredicate((widget) => widget is Cue), findsNothing);
        expect(find.text('Content'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
