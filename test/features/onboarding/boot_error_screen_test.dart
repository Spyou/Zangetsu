import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/onboarding/boot_error_screen.dart';

Future<void> _pump(
  WidgetTester tester, {
  String details = 'ArgumentError: something broke\n#0 someFrame',
  VoidCallback? onRetry,
}) async {
  await tester.pumpWidget(
    MaterialApp(home: BootErrorScreen(details: details, onRetry: onRetry)),
  );
}

void main() {
  group('BootErrorScreen', () {
    testWidgets('leads with reassurance, not a stack trace', (tester) async {
      await _pump(tester);

      expect(find.textContaining("didn't finish starting"), findsOneWidget);
      expect(
        find.textContaining('your account and anything synced to the cloud '
            'are safe'),
        findsOneWidget,
        reason: 'someone whose app will not open should be told nothing is lost',
      );
      // The scary part stays folded away until asked for.
      expect(find.textContaining('ArgumentError'), findsNothing);
      expect(find.text('Show details'), findsOneWidget);
    });

    testWidgets('reveals the error only when asked', (tester) async {
      await _pump(tester);

      await tester.tap(find.text('Show details'));
      await tester.pumpAndSettle();

      expect(find.textContaining('ArgumentError'), findsOneWidget);
      expect(
        find.text('Copy details'),
        findsOneWidget,
        reason: 'the whole point is that the user can send this to us',
      );
    });

    testWidgets('Try again calls back', (tester) async {
      var retried = 0;
      await _pump(tester, onRetry: () => retried++);

      await tester.tap(find.text('Try again'));
      await tester.pump();

      expect(retried, 1);
    });

    testWidgets('hides Try again when there is nothing to retry',
        (tester) async {
      await _pump(tester); // no onRetry

      expect(find.text('Try again'), findsNothing);
      expect(
        find.text('Reset app data'),
        findsOneWidget,
        reason: 'a recovery route must always remain',
      );
    });

    testWidgets('Reset confirms first and explains what survives',
        (tester) async {
      await _pump(tester);

      await tester.tap(find.text('Reset app data'));
      await tester.pumpAndSettle();

      expect(find.text('Reset app data?'), findsOneWidget);
      expect(
        find.textContaining('Your account and anything synced to the cloud '
            'are not touched'),
        findsOneWidget,
      );

      // Cancel leaves everything alone (and never touches Hive).
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Reset app data?'), findsNothing);
    });
  });
}
