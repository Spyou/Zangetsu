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

  testWidgets('OK toggles Anime and Movie/TV in one rail row', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvStreamKindRailToggle(
            navOpen: true,
            iconSlotWidth: 62,
            onToggle: (next) async {
              if (next != ZModePrefs.streamKind) {
                await ZModePrefs.setStreamKind(next);
              }
            },
          ),
        ),
      ),
    );
    expect(find.text('Anime'), findsOneWidget);
    expect(find.text('Movie/TV'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_rounded), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('tv-stream-kind-toggle')));
    await t.pump();
    await t.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await t.pump();
    expect(ZModePrefs.streamKind, StreamKind.movie);
  });
}
