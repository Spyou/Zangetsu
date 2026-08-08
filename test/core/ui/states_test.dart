import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/ui/states.dart';

void main() {
  group('EmptyState', () {
    testWidgets('renders icon + message with no button by default', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(icon: Icons.dns_rounded, message: 'Nothing here'),
          ),
        ),
      );

      expect(find.text('Nothing here'), findsOneWidget);
      expect(find.byIcon(Icons.dns_rounded), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets(
      'renders an action button when actionLabel + onAction are both given, '
      'and tapping it invokes onAction',
      (tester) async {
        var tapped = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: EmptyState(
                icon: Icons.dns_rounded,
                message: 'Nothing here',
                actionLabel: 'Add one',
                onAction: () => tapped = true,
              ),
            ),
          ),
        );

        expect(find.widgetWithText(FilledButton, 'Add one'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Add one'));
        await tester.pump();
        expect(tapped, isTrue);
      },
    );

    testWidgets('no button when only actionLabel is given (onAction missing)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(
              icon: Icons.dns_rounded,
              message: 'Nothing here',
              actionLabel: 'Add one',
            ),
          ),
        ),
      );

      expect(find.byType(FilledButton), findsNothing);
    });
  });
}
