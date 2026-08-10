import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';

void main() {
  testWidgets(
    'accessibleNavigation OFF: OK key still fires onTap (sighted user, unchanged)',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(accessibleNavigation: false),
          child: TvFocusable(
            autofocus: true,
            onTap: () => taps++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(taps, 1);
    },
  );

  testWidgets(
    'accessibleNavigation ON: OK key STILL fires onTap — Fire TV reports this '
    'flag true after the native player with no screen reader running, so '
    'activation must NOT be gated on it (regression: the old gate dead-keyed OK)',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(accessibleNavigation: true),
          child: TvFocusable(
            autofocus: true,
            onTap: () => taps++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(taps, 1);
    },
  );

  testWidgets(
    'the accessibility tap action (a real TalkBack activation) also fires onTap',
    (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(accessibleNavigation: true),
          child: TvFocusable(
            autofocus: true,
            onTap: () => taps++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // The Semantics(onTap: ...) wrapper exposes the accessibility tap action.
      final node = tester.getSemantics(find.byType(TvFocusable));
      node.owner!.performAction(node.id, SemanticsAction.tap);

      expect(taps, 1);
      handle.dispose();
    },
  );

  testWidgets(
    'a single press arriving on BOTH the OK key and the semantics tap within '
    'the dedup window fires onTap only once',
    (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(accessibleNavigation: true),
          child: TvFocusable(
            autofocus: true,
            onTap: () => taps++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      final node = tester.getSemantics(find.byType(TvFocusable));
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pumpAndSettle();

      expect(taps, 1);
      handle.dispose();
    },
  );
}
