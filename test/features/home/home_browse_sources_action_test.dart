import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/home/home_screen.dart';

/// The header's only way into the sources destination now that Sources
/// stopped being a mode — it must show for the entire time Z Mode is on, and
/// stay hidden the entire time it's off (Home is source-driven there, and the
/// switcher covers it).
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_browse_sources_action');
    Hive.init(tempDir.path);
    await ZModePrefs.init();
  });

  tearDown(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpAction(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomeBrowseSourcesAction())),
    );
  }

  testWidgets('Z Mode off: the sources icon is hidden', (tester) async {
    expect(ZModePrefs.enabled, isFalse);
    await pumpAction(tester);
    expect(find.byIcon(Icons.extension_outlined), findsNothing);
  });

  testWidgets('Z Mode on: the sources icon shows', (tester) async {
    // A real Hive write never drains under the pump-driven testWidgets
    // binding without runAsync — same gotcha as wrong_title_sheet_test.dart.
    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    await pumpAction(tester);
    expect(find.byIcon(Icons.extension_outlined), findsOneWidget);
  });

  testWidgets('flipping the toggle updates it without a restart', (tester) async {
    await pumpAction(tester);
    expect(find.byIcon(Icons.extension_outlined), findsNothing);

    await tester.runAsync(() => ZModePrefs.setEnabled(true));
    await tester.pump();
    expect(find.byIcon(Icons.extension_outlined), findsOneWidget);

    await tester.runAsync(() => ZModePrefs.setEnabled(false));
    await tester.pump();
    expect(find.byIcon(Icons.extension_outlined), findsNothing);
  });
}
