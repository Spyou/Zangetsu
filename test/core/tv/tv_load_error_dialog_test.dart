import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/tv/tv_load_error_dialog.dart';

void main() {
  testWidgets('TV load-error dialog shows the change-sources message',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showTvPlaybackLoadError(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load this episode"), findsOneWidget);
    expect(
      find.textContaining('try changing sources'),
      findsOneWidget,
    );
    expect(find.text('OK'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't load this episode"), findsNothing);
  });
}
