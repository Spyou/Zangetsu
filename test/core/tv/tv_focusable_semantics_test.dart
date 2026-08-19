import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';

void main() {
  testWidgets('labelled TvFocusable exposes label + button + tap action',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: TvFocusable(
        autofocus: true,
        semanticLabel: 'Play',
        onTap: () {},
        child: const SizedBox(width: 100, height: 100),
      ),
    ));
    await tester.pumpAndSettle();

    // All of these landing on ONE node (not split across two) is what
    // proves Focus's contributed focusable/focused merged into ours instead
    // of forming a second, competing node.
    final node = tester.getSemantics(find.byType(TvFocusable));
    expect(
      node,
      matchesSemantics(
        label: 'Play',
        isButton: true,
        isFocusable: true,
        isFocused: true,
        hasTapAction: true,
        // Framework-supplied for anything focusable; matchesSemantics fails on
        // any action it wasn't told to expect.
        hasFocusAction: true,
      ),
    );

    handle.dispose();
  });

  testWidgets('null semanticLabel does not crash and has no name',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: TvFocusable(
        onTap: () {},
        child: const SizedBox(width: 100, height: 100),
      ),
    ));
    await tester.pumpAndSettle();

    final node = tester.getSemantics(find.byType(TvFocusable));
    expect(
      node,
      matchesSemantics(
        isButton: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    handle.dispose();
  });
}
