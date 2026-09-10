import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/tv_track_helpers.dart';
import 'package:watch_app/core/theme/app_font_prefs.dart';
import 'package:watch_app/core/theme/app_text.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('app_font_prefs');
    Hive.init(dir.path);
    AppText.fontFamily = AppText.defaultFontFamily;
    await AppFontPrefs.init();
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('a fresh install is on the default', () {
    expect(AppFontPrefs.family, AppText.defaultFontFamily);
    expect(AppText.fontFamily, AppText.defaultFontFamily);
  });

  test('choosing a font applies it and bumps the revision', () async {
    final before = AppFontPrefs.revision.value;
    await AppFontPrefs.setFamily('Rubik');
    expect(AppFontPrefs.family, 'Rubik');
    // The styles have to follow — they are getters for exactly this reason.
    expect(AppText.fontFamily, 'Rubik');
    expect(AppText.body.fontFamily, 'Rubik');
    expect(AppText.largeTitle.fontFamily, 'Rubik');
    // main.dart rebuilds MaterialApp off this.
    expect(AppFontPrefs.revision.value, greaterThan(before));
  });

  test('a bundled choice survives a restart', () async {
    await AppFontPrefs.setFamily('Inter');
    AppText.fontFamily = 'something else entirely';
    await AppFontPrefs.init(); // as boot does
    expect(AppText.fontFamily, 'Inter');
  });

  test('a downloaded choice that cannot be re-fetched falls back', () async {
    // FontLoader registrations do not survive a restart, so boot re-fetches.
    // With no network (as here) the font is not on the device — applying it
    // anyway would draw the platform default and look like a broken setting,
    // so boot must fall back to the bundled default instead.
    await AppFontPrefs.setFamily('Montserrat');
    AppText.fontFamily = 'something else entirely';
    await AppFontPrefs.init();
    expect(AppText.fontFamily, AppText.defaultFontFamily);
    // The CHOICE is kept though — it comes back once the download succeeds.
    expect(AppFontPrefs.family, 'Montserrat');
  });

  test('a font that is no longer offered falls back, it does not stick', () async {
    // A family dropped from the list would otherwise leave the app asking for
    // one that pubspec never declares — which renders as the platform default
    // and reads as a bug rather than a choice.
    await Hive.box(AppFontPrefs.boxName).put('family', 'Comic Sans MS');
    expect(AppFontPrefs.family, AppText.defaultFontFamily);
  });

  test('a bundled font really is in the APK', () async {
    // pubspec is the contract for these: claiming bundled without declaring it
    // means no download is attempted AND Flutter has no such family, so it
    // silently draws the platform default.
    final pubspec = await File('pubspec.yaml').readAsString();
    for (final f in AppFontPrefs.fonts.where((f) => f.bundled)) {
      expect(
        pubspec.contains('- family: ${f.family}\n'),
        isTrue,
        reason: '"${f.family}" claims bundled but pubspec never declares it',
      );
    }
  });

  test('the default is bundled — it has to paint before any network', () {
    expect(AppFontPrefs.isBundled(AppText.defaultFontFamily), isTrue);
  });

  test('a downloadable font is NOT bundled, or it costs install size', () async {
    final pubspec = await File('pubspec.yaml').readAsString();
    for (final f in AppFontPrefs.fonts.where((f) => !f.bundled)) {
      expect(
        pubspec.contains('- family: ${f.family}\n'),
        isFalse,
        reason: '"${f.family}" is meant to download but is in the APK',
      );
      // And the fetcher has to know the filename, or ensure() can never work.
      expect(
        subtitleFontFileName(f.family),
        isNotNull,
        reason: '"${f.family}" has no file mapping, so it can never download',
      );
    }
  });

  test('no single-weight font is offered', () async {
    // Flutter fakes the bold on a single-weight file and every heading here is
    // w600 or heavier, so it looks smeared. Poppins and Lato are bundled and
    // both are single-weight — they must stay out of the picker.
    for (final f in AppFontPrefs.fonts) {
      expect(f.family, isNot('Poppins'));
      expect(f.family, isNot('Lato'));
    }
  });
}
