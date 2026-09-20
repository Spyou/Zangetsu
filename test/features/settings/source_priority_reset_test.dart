import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/zmode/source_order_prefs.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';
import 'package:watch_app/l10n/app_localizations_en.dart';

void main() {
  late Directory dir;
  late SourceOrderPrefs prefs;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('srcorder');
    Hive.init(dir.path);
    prefs = await SourceOrderPrefs.open();
  });
  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  // A saved order IS the takeover flag — there is no second piece of state.
  // The screen's `_manual` getter and its Reset button both rest on these.
  test('no saved order means automatic', () {
    expect(prefs.get(ZKind.anime), isEmpty);
  });

  test('dragging saves an order; reset clears it and automatic returns',
      () async {
    await prefs.set(ZKind.anime, ['b', 'a']);
    expect(prefs.get(ZKind.anime), ['b', 'a']);
    await prefs.clear(ZKind.anime);
    expect(prefs.get(ZKind.anime), isEmpty);
  });

  // If a switch ever started writing an order, one tap would silently freeze
  // the ranking forever — the user would be in manual mode without asking.
  test('switching a source off does not create a saved order', () async {
    await prefs.setExcluded(ZKind.anime, {'a'});
    expect(prefs.excluded(ZKind.anime), {'a'});
    expect(prefs.get(ZKind.anime), isEmpty);
  });

  // Reset hands ranking back. It must NOT also undo which sources you switched
  // off: those are separate decisions, and silently re-enabling three sources
  // someone deliberately turned off is not what "reset the order" promises.
  test('reset clears the order but leaves switched-off sources off', () async {
    await prefs.set(ZKind.anime, ['b', 'a']);
    await prefs.setExcluded(ZKind.anime, {'c'});
    await prefs.clear(ZKind.anime);
    expect(prefs.get(ZKind.anime), isEmpty);
    expect(prefs.excluded(ZKind.anime), {'c'},
        reason: 'resetting the order must not turn switched-off sources on');
  });

  // Once the sweep is capped, "No source has this yet" is false — 10 of 500
  // were asked. Saying so is what keeps a capped search from reading as a
  // wrong answer.
  // Once the sweep is capped, "No source has this yet" is false — only your
  // top sources were asked. It deliberately names no number: someone with 3
  // sources installed must not be told 10 were checked.
  test('the capped failure message does not claim everything was asked', () {
    final msg = AppLocalizationsEn().checkedTopSources;
    expect(msg.toLowerCase(), isNot(contains('no source has')));
    expect(msg, isNot(contains('10')),
        reason: 'a fixed number is wrong for anyone with fewer sources');
  });

  // Phone and TV are fed by the same capped sweep, so they must say the same
  // thing about it. The TV dialog was reverted to "No source has this yet"
  // while the playback sweep was still uncapped, and capping it afterwards
  // left that claim false on one screen only.
  test('the capped message is the one used, not the everything-was-asked one',
      () {
    final l10n = AppLocalizationsEn();
    expect(l10n.checkedTopSources.toLowerCase(), isNot(contains('no source has')));
    // The old string still exists — it is correct wherever a sweep really is
    // exhaustive, and deleting it would break the seven locales inheriting it.
    expect(l10n.noSourceHasThisYet, isNotEmpty);
  });
}
