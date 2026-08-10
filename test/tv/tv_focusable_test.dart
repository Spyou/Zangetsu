import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('OK key fires onTap for every variant', (tester) async {
    for (final v in TvFocusVariant.values) {
      var taps = 0;
      // Unique key per variant so each iteration builds a FRESH TvFocusable
      // state. Without it Flutter reuses the state at this tree position, and
      // its OK-activation dedupe window (which collapses a key+semantics double
      // fire) would swallow the next iteration's press as a repeat.
      await tester.pumpWidget(_host(TvFocusable(
        key: ValueKey(v),
        autofocus: true,
        variant: v,
        onTap: () => taps++,
        child: const SizedBox(width: 100, height: 100),
      )));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, 1, reason: 'variant $v should select on OK');
    }
  });

  testWidgets('builder receives focus state', (tester) async {
    await tester.pumpWidget(_host(TvFocusable(
      autofocus: true,
      variant: TvFocusVariant.pill,
      onTap: () {},
      builder: (focused) => Text(focused ? 'FOCUSED' : 'blur'),
    )));
    await tester.pump();
    expect(find.text('FOCUSED'), findsOneWidget);
  });
}
