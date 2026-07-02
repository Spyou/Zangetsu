import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/download/download_prefs.dart';
import 'package:watch_app/features/settings/download_location_screen.dart';

void main() {
  late Directory _dir;

  setUp(() async {
    _dir = await Directory.systemTemp.createTemp();
    Hive.init(_dir.path);
    await Hive.openBox(DownloadPrefs.boxName);
    GetIt.instance.registerSingleton<DownloadPrefs>(DownloadPrefs());
  });

  tearDown(() async {
    await GetIt.instance.reset();
    await Hive.deleteFromDisk();
    if (_dir.existsSync()) await _dir.delete(recursive: true);
  });

  testWidgets('renders Choose folder tile and default current-location label',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: DownloadLocationScreen()),
    );
    await tester.pump();

    expect(find.text('Choose folder…'), findsOneWidget);
    expect(find.text('Downloads › Zangetsu'), findsOneWidget);
  });
}
