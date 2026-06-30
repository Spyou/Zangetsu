import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';

void main() {
  testWidgets('TvFocusable fires onTap on OK key when focused', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: TvFocusable(
        autofocus: true,
        onTap: () => taps++,
        child: const SizedBox(width: 100, height: 100),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(taps, 1);
  });
}
