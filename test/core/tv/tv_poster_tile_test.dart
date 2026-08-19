import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_focusable.dart';
import 'package:watch_app/core/tv/tv_poster_tile.dart';

void main() {
  testWidgets(
    'TvPosterTile exposes the title as the focusable\'s semantics label, '
    'and the sibling title Text is excluded (not announced twice)',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          // Real call sites always give the tile a bounded width (grid cell);
          // bound it here too so AspectRatio doesn't blow up against the
          // unconstrained test viewport.
          home: Center(
            child: SizedBox(
              width: 180,
              child: TvPosterTile(title: 'Attack on Titan', onTap: () {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final node = tester.getSemantics(find.byType(TvFocusable));
      expect(
        node,
        matchesSemantics(
          label: 'Attack on Titan',
          isButton: true,
          isFocusable: true,
          hasTapAction: true,
          // Framework-supplied for anything focusable; matchesSemantics fails
          // on any action it wasn't told to expect.
          hasFocusAction: true,
        ),
      );

      // The visible title Text is still on screen for sighted users...
      expect(find.text('Attack on Titan'), findsOneWidget);
      // ...but only ONE node in the whole semantics tree carries the title —
      // if the sibling Text weren't excluded, TalkBack would hear it twice.
      expect(find.bySemanticsLabel('Attack on Titan'), findsOneWidget);

      handle.dispose();
    },
  );
}
