import 'package:flutter/gestures.dart';
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

  testWidgets(
    'with onLongPress, a short OK press still fires onTap (not long-press)',
    (tester) async {
      var taps = 0;
      var longs = 0;
      await tester.pumpWidget(MaterialApp(
        home: TvFocusable(
          autofocus: true,
          onTap: () => taps++,
          onLongPress: () => longs++,
          child: const SizedBox(width: 100, height: 100),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      expect(taps, 0);
      expect(longs, 0);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, 1);
      expect(longs, 0);
    },
  );

  testWidgets(
    'with onLongPress, holding OK past the long-press timeout fires onLongPress only',
    (tester) async {
      var taps = 0;
      var longs = 0;
      await tester.pumpWidget(MaterialApp(
        home: TvFocusable(
          autofocus: true,
          onTap: () => taps++,
          onLongPress: () => longs++,
          child: const SizedBox(width: 100, height: 100),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(longs, 1);
      expect(taps, 0);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(longs, 1);
      expect(taps, 0);
    },
  );

  testWidgets(
    'TvFocusable focused border is a white outline',
    (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TvFocusable(
          autofocus: true,
          onTap: () {},
          child: const SizedBox(width: 100, height: 100),
        ),
      ));
      await tester.pumpAndSettle();

      // When focused, the DecoratedBox uses a clean white outline (premium,
      // no accent tint).
      final decoratedBox =
          tester.widget<DecoratedBox>(find.byType(DecoratedBox).first);
      final decoration = decoratedBox.decoration as BoxDecoration;
      expect(
        decoration.border,
        isA<Border>().having(
          (b) => b.top.color,
          'top border color',
          Colors.white,
        ),
      );
    },
  );

  testWidgets(
    'TvFocusable unfocused border is transparent',
    (tester) async {
      // Render without autofocus so the widget starts unfocused.
      await tester.pumpWidget(MaterialApp(
        home: TvFocusable(
          autofocus: false,
          onTap: () {},
          child: const SizedBox(width: 100, height: 100),
        ),
      ));
      await tester.pumpAndSettle();

      final decoratedBox =
          tester.widget<DecoratedBox>(find.byType(DecoratedBox).first);
      final decoration = decoratedBox.decoration as BoxDecoration;
      expect(
        decoration.border,
        isA<Border>().having(
          (b) => b.top.color,
          'top border color',
          Colors.transparent,
        ),
      );
    },
  );
}
