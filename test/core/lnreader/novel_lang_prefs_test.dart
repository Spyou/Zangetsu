import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/lnreader/novel_lang_prefs.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('novel_lang');
    Hive.init(dir.path);
    await NovelLangPrefs.init();
  });

  tearDown(() async {
    try {
      await Hive.close();
    } catch (_) {}
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('enabled is null until configured, then reflects the saved set', () async {
    final p = NovelLangPrefs();
    expect(p.enabled, isNull); // unconfigured → screen uses its own default
    await p.setEnabled({'en', 'id'});
    expect(p.enabled, {'en', 'id'});
  });

  test('an empty set is respected — distinct from the unconfigured null', () async {
    final p = NovelLangPrefs();
    await p.setEnabled(<String>{});
    expect(p.enabled, isNotNull);
    expect(p.enabled, isEmpty);
  });

  test('setEnabled persists across instances and notifies', () async {
    var notified = 0;
    final p = NovelLangPrefs()..addListener(() => notified++);
    await p.setEnabled({'zh'});
    expect(notified, 1);
    expect(NovelLangPrefs().enabled, {'zh'}); // a fresh instance reads the box
  });

  test('returns null / no-ops when the box is closed (never throws)', () async {
    await Hive.close();
    final p = NovelLangPrefs();
    expect(p.enabled, isNull);
    await p.setEnabled({'en'}); // must not throw
    expect(p.enabled, isNull);
  });
}
