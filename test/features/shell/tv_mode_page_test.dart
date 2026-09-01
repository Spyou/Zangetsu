import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/zmode_prefs.dart';
import 'package:watch_app/features/shell/tv_mode_page.dart';

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tvmode');
    Hive.init(dir.path);
    await ZModePrefs.init();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('offers Anime and Movie/TV and stores the pick', (t) async {
    await t.pumpWidget(const MaterialApp(home: TvModePage(reloadHome: false)));
    expect(find.text('Anime'), findsOneWidget);
    expect(find.text('Movie/TV'), findsOneWidget);
    // The tap triggers a real (fire-and-forget) Hive write; FakeAsync never
    // drains that on its own, so tearDown's Hive.close() hangs waiting on it
    // without runAsync (same gotcha as mode_switcher_test.dart).
    await t.runAsync(() async {
      await t.tap(find.text('Movie/TV'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await t.pump();
    expect(ZModePrefs.streamKind, StreamKind.movie);
  });
}
