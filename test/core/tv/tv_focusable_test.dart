import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/theme/app_colors.dart';
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
    'TvFocusable focused border uses accent color, not white',
    (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: TvFocusable(
          autofocus: true,
          onTap: () {},
          child: const SizedBox(width: 100, height: 100),
        ),
      ));
      await tester.pumpAndSettle();

      // When focused, the DecoratedBox should use the accent color border.
      final decoratedBox =
          tester.widget<DecoratedBox>(find.byType(DecoratedBox).first);
      final decoration = decoratedBox.decoration as BoxDecoration;
      expect(
        decoration.border,
        isA<Border>().having(
          (b) => b.top.color,
          'top border color',
          AppColors.accent,
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
