import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/source_score_store.dart';

void main() {
  late Directory dir;
  late SourceScoreStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('srcscore');
    Hive.init(dir.path);
    store = await SourceScoreStore.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a source nobody has played reads zero, not null', () {
    expect(store.plays('hianime'), 0);
  });

  test('bump counts up and each source counts separately', () async {
    await store.bump('hianime');
    await store.bump('hianime');
    await store.bump('animecube');
    expect(store.plays('hianime'), 2);
    expect(store.plays('animecube'), 1);
  });

  test('counts survive a reopen — ranking would reset every launch otherwise',
      () async {
    await store.bump('hianime');
    await Hive.close();
    Hive.init(dir.path);
    final again = await SourceScoreStore.open();
    expect(again.plays('hianime'), 1);
  });

  test('clear wipes every count', () async {
    await store.bump('hianime');
    await store.clear();
    expect(store.plays('hianime'), 0);
  });
}
