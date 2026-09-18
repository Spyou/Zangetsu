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
  test('the capped failure message says how many were actually checked', () {
    final msg = AppLocalizationsEn().checkedTopSources(kAutoResolveCap);
    expect(msg, contains('10'));
    expect(msg.toLowerCase(), isNot(contains('no source has')),
        reason: 'it must not repeat the claim that everything was asked');
  });
}
