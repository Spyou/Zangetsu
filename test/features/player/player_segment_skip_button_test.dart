import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/player_screen.dart';

void main() {
  testWidgets(
    'skip timer runs with controls open and resets for a new segment',
    (tester) async {
      var taps = 0;
      Future<void> show({
        required bool controlsVisible,
        String label = 'Skip Intro',
      }) {
        return tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: PlayerSegmentSkipButton(
                key: ValueKey(label),
                label: label,
                controlsVisible: controlsVisible,
                onTap: () => taps++,
              ),
            ),
          ),
        );
      }

      await show(controlsVisible: false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      final fill = find.descendant(
        of: find.byType(PlayerSegmentSkipButton),
        matching: find.byWidgetPredicate(
          (widget) => widget is ClipRect && widget.clipper != null,
        ),
      );
      expect(
        tester.widget<ClipRect>(fill).clipper!.getClip(const Size(100, 44)),
        const Rect.fromLTWH(0, 0, 40, 44),
      );
      await show(controlsVisible: true);
      await tester.pump(const Duration(seconds: 7));
      expect(find.text('Skip Intro'), findsOneWidget);
      expect(
        tester.widget<ClipRect>(fill).clipper!.getClip(const Size(100, 44)),
        const Rect.fromLTWH(0, 0, 100, 44),
      );

      await show(controlsVisible: false);
      expect(find.text('Skip Intro'), findsNothing);

      await show(controlsVisible: true);
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerSegmentSkipButton),
          matching: find.byType(InkWell),
        ),
      );
      expect(taps, 1);
      await show(controlsVisible: false, label: 'Skip Recap');
      expect(find.text('Skip Recap'), findsOneWidget);
    },
  );
}
