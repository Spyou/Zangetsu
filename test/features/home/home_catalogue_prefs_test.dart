import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/mode/content_mode.dart';
import 'package:watch_app/features/home/home_catalogue_prefs.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('home_catalogue_prefs');
    Hive.init(tempDir.path);
    await Hive.openBox(HomeCataloguePrefs.boxName);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('new installs keep the existing metadata Home', () {
    expect(HomeCataloguePrefs.sourceSelected, isFalse);
    expect(HomeCataloguePrefs.sourceId, isNull);
    expect(HomeCataloguePrefs.sourceIdFor(ContentMode.anime), isNull);
    expect(HomeCataloguePrefs.sourceIdFor(ContentMode.manga), isNull);
  });

  test(
    'source catalogue and chosen source survive reopening the box',
    () async {
      await HomeCataloguePrefs.setSourceSelected(true);
      await HomeCataloguePrefs.setSourceIdFor(
        ContentMode.anime,
        'cs:anikoto',
      );
      await Hive.box(HomeCataloguePrefs.boxName).close();
      await Hive.openBox(HomeCataloguePrefs.boxName);

      expect(HomeCataloguePrefs.sourceSelected, isTrue);
      expect(
        HomeCataloguePrefs.sourceIdFor(ContentMode.anime),
        'cs:anikoto',
      );

      await HomeCataloguePrefs.setSourceSelected(false);
      expect(HomeCataloguePrefs.sourceSelected, isFalse);
      expect(
        HomeCataloguePrefs.sourceIdFor(ContentMode.anime),
        'cs:anikoto',
      );
    },
  );

  test('anime and manga remember different sources', () async {
    await HomeCataloguePrefs.setSourceIdFor(ContentMode.anime, 'cs:anikoto');
    await HomeCataloguePrefs.setSourceIdFor(ContentMode.manga, 'mihon:reader');

    // Switching modes must not clobber: each mode reads its own slot.
    expect(HomeCataloguePrefs.sourceIdFor(ContentMode.anime), 'cs:anikoto');
    expect(HomeCataloguePrefs.sourceIdFor(ContentMode.manga), 'mihon:reader');

    // Rewriting one mode leaves the other alone (the reported bug: manga's
    // fallback overwrote anime's pick and vice versa).
    await HomeCataloguePrefs.setSourceIdFor(ContentMode.manga, 'mihon:other');
    expect(HomeCataloguePrefs.sourceIdFor(ContentMode.anime), 'cs:anikoto');
    expect(HomeCataloguePrefs.sourceIdFor(ContentMode.manga), 'mihon:other');
  });

  test('a pre-split single slot migrates into the mode once', () async {
    await HomeCataloguePrefs.setSourceId('cs:anikoto');

    expect(
      HomeCataloguePrefs.sourceIdFor(ContentMode.anime),
      'cs:anikoto',
    );

    // First per-mode write retires the shared slot.
    await HomeCataloguePrefs.setSourceIdFor(ContentMode.anime, 'cs:other');
    expect(HomeCataloguePrefs.sourceId, isNull);
    expect(
      HomeCataloguePrefs.sourceIdFor(ContentMode.anime),
      'cs:other',
    );
  });

  test('changing the catalogue selection notifies the mounted Home', () async {
    final changes = <bool>[];
    final selection = HomeCataloguePrefs.sourceSelection;
    void onChanged() => changes.add(selection.value);
    selection.addListener(onChanged);
    addTearDown(() => selection.removeListener(onChanged));

    await HomeCataloguePrefs.setSourceSelected(true);

    expect(changes, [true]);
    expect(selection.value, isTrue);
  });

  test('a closed box falls back without changing Home', () async {
    await Hive.box(HomeCataloguePrefs.boxName).close();
    expect(HomeCataloguePrefs.sourceSelected, isFalse);
    expect(HomeCataloguePrefs.sourceId, isNull);
    expect(HomeCataloguePrefs.sourceIdFor(ContentMode.anime), isNull);
  });
}
