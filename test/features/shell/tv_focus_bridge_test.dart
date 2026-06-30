// Tests for the edge-gated D-pad focus bridge used in RootShellTv.
//
// These tests mirror the fixed handler logic exactly so they can run without
// any GetIt / AppwriteService / HomeCubit scaffolding.  They verify the
// behavioural contract of the two bug fixes:
//
//   BUG-1: arrowLeft on a non-edge content node must move left within the
//           content zone, NOT eject focus to the nav rail.
//
//   BUG-2: arrowRight from the rail must land on a real content leaf (not the
//           bare FocusScopeNode, which leaves nothing visually highlighted).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ── BUG-1: edge-gated arrowLeft ──────────────────────────────────────────

  testWidgets(
    'arrowLeft on a non-edge content node moves to left neighbour, not rail',
    (tester) async {
      final railScope = FocusScopeNode(debugLabel: 'rail');
      final contentScope = FocusScopeNode(debugLabel: 'content');
      final leftNode = FocusNode(debugLabel: 'left-item');
      final rightNode = FocusNode(debugLabel: 'right-item');

      // Exact copy of the fixed _onContentKey from RootShellTv.
      KeyEventResult onContentKey(FocusNode _, KeyEvent event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          final moved = FocusManager.instance.primaryFocus
                  ?.focusInDirection(TraversalDirection.left) ??
              false;
          if (!moved) railScope.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }

      addTearDown(() {
        railScope.dispose();
        contentScope.dispose();
        leftNode.dispose();
        rightNode.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                // Rail zone (100 px, no key handler for this test).
                Focus(
                  focusNode: railScope,
                  child: const SizedBox(width: 100, height: 600),
                ),
                // Content zone: two side-by-side focusable leaves.
                Expanded(
                  child: Focus(
                    focusNode: contentScope,
                    onKeyEvent: onContentKey,
                    child: Row(
                      children: [
                        Focus(
                          focusNode: leftNode,
                          child: const SizedBox(width: 200, height: 200),
                        ),
                        Focus(
                          focusNode: rightNode,
                          child: const SizedBox(width: 200, height: 200),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Place focus on the right (non-leftmost) content node.
      rightNode.requestFocus();
      await tester.pump();
      expect(rightNode.hasFocus, isTrue);

      // D-pad LEFT.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      // Focus must have moved to the left neighbour, NOT jumped to the rail.
      expect(
        leftNode.hasFocus,
        isTrue,
        reason: 'arrowLeft from a non-edge node should reach the left neighbour',
      );
      expect(
        railScope.hasFocus,
        isFalse,
        reason: 'arrowLeft mid-row must NOT eject focus to the nav rail',
      );
    },
  );

  testWidgets(
    'arrowLeft at the left edge of content ejects focus to the rail',
    (tester) async {
      final railScope = FocusScopeNode(debugLabel: 'rail');
      final contentScope = FocusScopeNode(debugLabel: 'content');
      final railItemNode = FocusNode(debugLabel: 'rail-item');
      final onlyContentNode = FocusNode(debugLabel: 'only-content-item');

      KeyEventResult onContentKey(FocusNode _, KeyEvent event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          final moved = FocusManager.instance.primaryFocus
                  ?.focusInDirection(TraversalDirection.left) ??
              false;
          if (!moved) railScope.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }

      addTearDown(() {
        railScope.dispose();
        contentScope.dispose();
        railItemNode.dispose();
        onlyContentNode.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Focus(
                  focusNode: railScope,
                  child: Focus(
                    focusNode: railItemNode,
                    child: const SizedBox(width: 100, height: 600),
                  ),
                ),
                Expanded(
                  child: Focus(
                    focusNode: contentScope,
                    onKeyEvent: onContentKey,
                    // Single node: no left neighbour exists.
                    child: Focus(
                      focusNode: onlyContentNode,
                      child: const SizedBox(width: 400, height: 200),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      onlyContentNode.requestFocus();
      await tester.pump();
      expect(onlyContentNode.hasFocus, isTrue);

      // D-pad LEFT from the only content node → no left neighbour → goes to rail.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();

      expect(
        railScope.hasFocus,
        isTrue,
        reason: 'arrowLeft at the left edge should eject focus to the rail',
      );
    },
  );

  // ── BUG-2: right-from-rail lands on a real leaf ──────────────────────────

  testWidgets(
    'arrowRight from rail focuses first traversable content leaf on first entry',
    (tester) async {
      final railScope = FocusScopeNode(debugLabel: 'rail');
      final contentScope = FocusScopeNode(debugLabel: 'content');
      final railItemNode = FocusNode(debugLabel: 'rail-item');
      final contentLeaf = FocusNode(debugLabel: 'content-leaf');

      // Exact copy of the fixed _onRailKey from RootShellTv.
      KeyEventResult onRailKey(FocusNode _, KeyEvent event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          final lastFocused = contentScope.focusedChild;
          if (lastFocused != null) {
            lastFocused.requestFocus();
          } else {
            final first = contentScope.traversalDescendants
                .where((n) => n.canRequestFocus)
                .firstOrNull;
            first?.requestFocus();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }

      addTearDown(() {
        railScope.dispose();
        contentScope.dispose();
        railItemNode.dispose();
        contentLeaf.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Focus(
                  focusNode: railScope,
                  onKeyEvent: onRailKey,
                  child: Focus(
                    focusNode: railItemNode,
                    child: const SizedBox(width: 100, height: 600),
                  ),
                ),
                Expanded(
                  child: Focus(
                    focusNode: contentScope,
                    child: Focus(
                      focusNode: contentLeaf,
                      child: const SizedBox(width: 400, height: 200),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Start in the rail (first entry — contentScope.focusedChild is null).
      railItemNode.requestFocus();
      await tester.pump();
      expect(railItemNode.hasFocus, isTrue);

      // D-pad RIGHT from rail.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();

      // A real leaf must be focused — not the bare content scope.
      expect(
        contentLeaf.hasFocus,
        isTrue,
        reason: 'arrowRight from rail on first entry must focus the content leaf',
      );
    },
  );
}
