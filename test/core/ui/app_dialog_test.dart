import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/di/injector.dart';
import 'package:watch_app/core/ui/app_dialog.dart';

void main() {
  setUp(() {
    sl.registerSingleton<AppMode>(const AppMode(isTv: false));
  });

  tearDown(sl.reset);

  testWidgets('AppDialog.confirm returns true on the confirm action',
      (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await AppDialog.confirm(
                  context,
                  title: 'Delete all',
                  message: 'This cannot be undone.',
                  confirmLabel: 'Delete',
                  destructive: true,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(TvAlertDialog), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.byType(TvAlertDialog), findsNothing);
  });

  testWidgets('AppDialog.alert dismisses on OK', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => AppDialog.alert(
                context,
                title: 'Restore complete',
                message: 'Library restored',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Restore complete'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Restore complete'), findsNothing);
  });
}
