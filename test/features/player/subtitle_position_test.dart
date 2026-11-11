import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/player/subtitle_style.dart';

void main() {
  testWidgets('multiline subtitles reach top, centre and bottom on any frame', (
    tester,
  ) async {
    for (final height in [180.0, 600.0]) {
      for (final position in [0, 50, 100]) {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SizedBox(
                width: 320,
                height: height,
                child: PositionedSubtitle(
                  text: 'First line\nSecond line',
                  position: position,
                  style: const TextStyle(fontSize: 160),
                ),
              ),
            ),
          ),
        );
        final frame = tester.getRect(find.byType(PositionedSubtitle));
        final text = tester.getRect(find.text('First line\nSecond line'));
        if (position == 0) expect(text.top, closeTo(frame.top, .1));
        if (position == 50)
          expect(text.center.dy, closeTo(frame.center.dy, .1));
        if (position == 100) expect(text.bottom, closeTo(frame.bottom, .1));
        expect(tester.takeException(), isNull);
      }
    }
  });
}
