import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/core/tv/tv_route_pop_guard.dart';

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
    'waitForKeyUp fires onTap on KeyUp, not KeyDown',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: TvFocusable(
          autofocus: true,
          waitForKeyUp: true,
          onTap: () => taps++,
          child: const SizedBox(width: 100, height: 100),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, 0);

      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, 1);
    },
  );

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

  testWidgets(
    'TvFocusable ignores OK while TvRoutePopGuard is active',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: TvFocusable(
          autofocus: true,
          onTap: () => taps++,
          child: const SizedBox(width: 100, height: 100),
        ),
      ));
      await tester.pumpAndSettle();

      TvRoutePopGuard.markPopped();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(taps, 0);
    },
  );

  testWidgets(
    'a background autofocus does not steal focus from an open dialog, '
    'and takes it once the dialog closes',
    (tester) async {
      final showLate = ValueNotifier(false);
      final lateNode = FocusNode(debugLabel: 'late');
      final dialogNode = FocusNode(debugLabel: 'dialog');
      addTearDown(() {
        showLate.dispose();
        lateNode.dispose();
        dialogNode.dispose();
      });
      late BuildContext homeContext;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) {
            homeContext = context;
            return ValueListenableBuilder<bool>(
              valueListenable: showLate,
              builder: (_, show, _) => show
                  ? TvFocusable(
                      focusNode: lateNode,
                      autofocus: true,
                      onTap: () {},
                      child: const SizedBox(width: 100, height: 100),
                    )
                  : const SizedBox.shrink(),
            );
          },
        ),
      ));

      showDialog<void>(
        context: homeContext,
        builder: (_) => Dialog(
          child: TvFocusable(
            focusNode: dialogNode,
            autofocus: true,
            onTap: () {},
            child: const SizedBox(width: 80, height: 40),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(dialogNode.hasPrimaryFocus, isTrue);

      // Home rows arrive late and mount an autofocused button underneath.
      showLate.value = true;
      await tester.pumpAndSettle();
      expect(dialogNode.hasPrimaryFocus, isTrue);
      expect(lateNode.hasFocus, isFalse);

      Navigator.of(homeContext).pop();
      await tester.pumpAndSettle();
      expect(lateNode.hasPrimaryFocus, isTrue);
    },
  );

  testWidgets('autofocus on the current route still works', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const SizedBox.shrink(),
    ));
    nav.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => TvFocusable(
        focusNode: node,
        autofocus: true,
        onTap: () {},
        child: const SizedBox(width: 100, height: 100),
      ),
    ));
    await tester.pumpAndSettle();
    expect(node.hasPrimaryFocus, isTrue);
  });
}
