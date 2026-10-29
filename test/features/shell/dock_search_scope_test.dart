import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/features/home/home_catalogue_prefs.dart';
import 'package:watch_app/features/shell/root_shell.dart';

/// The dock Search tab must search what Home is showing: a selected source
/// catalogue (e.g. AniKoto) means source search, otherwise metadata search —
/// exactly what the Home header icon passes as `fixedSourceId`.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('dock_search_scope');
    Hive.init(tempDir.path);
    await Hive.openBox(HomeCataloguePrefs.boxName);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('dock search follows the Home catalogue selection', () async {
    await HomeCataloguePrefs.setSourceSelected(true);
    await HomeCataloguePrefs.setSourceId('cs:anikoto');

    expect(dockSearchFixedSourceId(), 'cs:anikoto');
  });

  test('dock search is metadata search when Home shows metadata', () async {
    await HomeCataloguePrefs.setSourceSelected(false);
    await HomeCataloguePrefs.setSourceId('cs:anikoto');

    expect(dockSearchFixedSourceId(), isNull);
  });

  test('a selected catalogue with no id falls back to metadata', () async {
    await HomeCataloguePrefs.setSourceSelected(true);

    expect(dockSearchFixedSourceId(), isNull);
  });
}
