import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/theme/theme_controller.dart';
import 'package:watch_app/core/theme/theme_repaint_observer.dart';

void main() {
  testWidgets('live routes rebuild when the theme revision bumps', (
    tester,
  ) async {
    final observer = ThemeRepaintObserver();
    var builds = 0;

    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) {
                  builds++;
                  return const Text('pushed');
                },
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(builds, 1);

    ThemeController.revision.value++;
    await tester.pump();

    expect(builds, 2);
  });
}
