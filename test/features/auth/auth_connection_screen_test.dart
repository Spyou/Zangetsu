import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/auth/auth_connection_screen.dart';

void main() {
  Future<void> show(
    WidgetTester tester,
    ValueNotifier<AuthConnectionPhase> phase,
  ) => tester.pumpWidget(
    MaterialApp(
      home: AuthConnectionOverlay(
        phase: phase,
        child: const Scaffold(body: Text('Saved library')),
      ),
    ),
  );

  testWidgets('normal launch has no connection screen', (tester) async {
    final phase = ValueNotifier(AuthConnectionPhase.idle);
    await show(tester, phase);
    expect(find.text('Getting things ready…'), findsNothing);
    expect(find.text('Saved library'), findsOneWidget);
  });

  testWidgets('switch shows preparation and confirmation then releases app', (
    tester,
  ) async {
    final phase = ValueNotifier(AuthConnectionPhase.preparing);
    await show(tester, phase);
    expect(find.text('Getting things ready…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    phase.value = AuthConnectionPhase.ready;
    await tester.pump();
    expect(find.text('All set. Welcome back!'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(phase.value, AuthConnectionPhase.idle);
    expect(find.text('All set. Welcome back!'), findsNothing);
  });

  testWidgets(
    'failed connection never claims success and can reveal saved app',
    (tester) async {
      final phase = ValueNotifier(AuthConnectionPhase.failed);
      await show(tester, phase);
      expect(find.text('All set. Welcome back!'), findsNothing);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(phase.value, AuthConnectionPhase.idle);
      expect(find.text('Saved library'), findsOneWidget);
    },
  );
}
