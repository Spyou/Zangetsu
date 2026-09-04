import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/category_store.dart';

// A category made under Streaming used to appear as an empty tab under Manga
// and Novel too — categories are global and the screen only hid the ones that
// held nothing of the kind on screen, which a brand-new one never does.
// New categories now remember the mode they were made in; the ones already on
// people's devices carry no mode and keep the old rules.

void main() {
  late Directory dir;
  late CategoryStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('category_kind_test');
    Hive.init(dir.path);
    await Hive.openBox(CategoryStore.boxName);
    store = CategoryStore();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a new category remembers the mode it was made in', () async {
    final made = await store.create('Gym', kind: 'anime');
    expect(made, isNotNull);
    expect(made!.kind, 'anime');
    expect(store.all().single.kind, 'anime');
  });

  test('the mode survives a round trip through storage', () async {
    await store.create('Reading pile', kind: 'manga');
    // all() re-reads and re-parses from the box, which is where a dropped
    // field would show up.
    expect(store.all().single.kind, 'manga');
  });

  test('a category made without a mode stays without one', () async {
    // The legacy shape: nothing written, nothing invented on read.
    final made = await store.create('Old one');
    expect(made!.kind, isNull);
    expect(store.all().single.kind, isNull);
  });

  test('an unknown or blank kind reads as no kind, not as a mode', () async {
    await store.create('Gym', kind: 'anime');
    final raw = store.all().single.toMap();
    expect(ListCategory.fromMap({...raw, 'kind': ''})!.kind, isNull);
    expect(ListCategory.fromMap({...raw}..remove('kind'))!.kind, isNull);
  });

  test('the stored map omits the field entirely when there is no mode',
      () async {
    // It is sent nowhere, but an absent key is what the older readers expect.
    await store.create('Old one');
    expect(store.all().single.toMap().containsKey('kind'), isFalse);
  });
}
