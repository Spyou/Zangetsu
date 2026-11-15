import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/backup/stremio_backup_password_dialog.dart';

void main() {
  testWidgets('requires matching passwords before exporting addon URLs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showDialog<String>(
                context: context,
                builder: (_) =>
                    const StremioBackupPasswordDialog(confirm: true),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'password-one');
    await tester.enterText(find.byType(TextField).last, 'password-two');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(selected, isNull);
    await tester.enterText(find.byType(TextField).last, 'password-one');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(selected, 'password-one');
  });
}
