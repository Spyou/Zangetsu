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
    'accessibleNavigation ON: OK key is ignored, semantics tap action fires onTap (TalkBack path)',
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

      // The D-pad OK key must NOT trigger onTap — TalkBack owns activation
      // while a screen reader is running.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(taps, 0);

      // TalkBack activates via the accessibility tap action, which the
      // Semantics(onTap: ...) wrapper still exposes — that path must work.
      final node = tester.getSemantics(find.byType(TvFocusable));
      node.owner!.performAction(node.id, SemanticsAction.tap);
      expect(taps, 1);

      handle.dispose();
    },
  );
}
