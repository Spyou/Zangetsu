// Custom subtitle fonts: the user picks a .ttf/.otf and it has to work in the
// Flutter overlay (FontLoader), on the native TV player (a file path), and in
// libass (which matches the family recorded INSIDE the file).
//
// The failure this guards against is silent: a font that is stored but never
// resolved renders as the default, and nothing tells the user why.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/app_mode.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';
import 'package:watch_app/features/player/player_screen.dart';
import 'package:watch_app/features/player/subtitle_font_service.dart';
import 'package:watch_app/l10n/app_localizations.dart';

void main() {
  late Directory dir;
  late PlaybackPrefs prefs;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = await Directory.systemTemp.createTemp('custom_font');
    // The service resolves sub_fonts/ through path_provider; point it at the
    // temp dir so each test gets its own folder.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    Hive.init(dir.path);
    await PlaybackPrefs.init();
    prefs = PlaybackPrefs();
    GetIt.instance.registerSingleton<PlaybackPrefs>(prefs);
  });

  tearDown(() async {
    // The service caches its directory in a singleton, so reset it between
    // tests or the second test reuses the first test's temp folder.
    SubtitleFontService.instance.resetForTest();
    await GetIt.instance.reset();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  testWidgets('native styling can use the shared sheet and receive live changes', (
    tester,
  ) async {
    GetIt.instance.registerSingleton<AppMode>(const AppMode(isTv: false));
    await GetIt.instance.unregister<PlaybackPrefs>();
    final stylePrefs = _StyleTestPrefs();
    GetIt.instance.registerSingleton<PlaybackPrefs>(stylePrefs);
    ModalRoute<dynamic>? route;
    var changed = false;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => openSubtitleStyleSheet(
            context,
            null,
            () {},
            onRoute: (value) => route = value,
            onStyleChanged: () async => changed = true,
          ),
          child: const Text('Open style'),
        );
      })),
    ));
    await tester.tap(find.text('Open style'));
    await tester.pumpAndSettle();
    expect(route, isA<ModalBottomSheetRoute<void>>());
    expect(find.text('The quick brown fox'), findsOneWidget);

    final swatch = tester.widget<GestureDetector>(find.ancestor(
      of: find.text('Yellow').first,
      matching: find.byWidgetPredicate(
        (widget) => widget is GestureDetector && widget.child is Column && widget.onTap != null,
      ),
    ).first);
    swatch.onTap!();
    await tester.pump();
    expect(changed, isTrue);
    expect(stylePrefs.subtitleColorHex, '#FFFF00FF');
  });

  group('customSubtitleFonts pref', () {
    test('starts empty and round-trips', () async {
      expect(prefs.customSubtitleFonts, isEmpty);
      await prefs.setCustomSubtitleFonts({'Kosugi Maru': 'custom_Kosugi_Maru.ttf'});
      expect(prefs.customSubtitleFonts, {'Kosugi Maru': 'custom_Kosugi_Maru.ttf'});
    });

    test('survives reopening the box', () async {
      await prefs.setCustomSubtitleFonts({'Vazirmatn': 'custom_Vazirmatn.ttf'});
      await Hive.close();
      Hive.init(dir.path);
      await PlaybackPrefs.init();
      expect(PlaybackPrefs().customSubtitleFonts, {
        'Vazirmatn': 'custom_Vazirmatn.ttf',
      });
    });

    test('a junk value reads as empty rather than throwing', () async {
      // A hand-edited or half-migrated box must not take the player down.
      await Hive.box(PlaybackPrefs.boxName).put('customSubtitleFonts', 'nonsense');
      expect(prefs.customSubtitleFonts, isEmpty);
    });

    test('holds several fonts at once', () async {
      await prefs.setCustomSubtitleFonts({
        'Kosugi Maru': 'custom_Kosugi_Maru.ttf',
        'Vazirmatn': 'custom_Vazirmatn.otf',
      });
      expect(prefs.customSubtitleFonts.length, 2);
    });
  });

  group('SubtitleFontService with a custom font', () {
    // isAvailable/ensure must consult the custom map BEFORE
    // subtitleFontFileName, which knows only the ten built-in families.
    test('an unknown family is unavailable', () async {
      expect(await SubtitleFontService.instance.isAvailable('Kosugi Maru'), isFalse);
    });

    test('a registered custom font whose file exists is available', () async {
      final fonts = Directory('${dir.path}/sub_fonts')..createSync();
      File('${fonts.path}/custom_Kosugi_Maru.ttf').writeAsBytesSync([0, 1, 2]);
      await prefs.setCustomSubtitleFonts({'Kosugi Maru': 'custom_Kosugi_Maru.ttf'});

      expect(await SubtitleFontService.instance.isAvailable('Kosugi Maru'), isTrue);
    });

    test('ensure() succeeds for a custom font and registers it', () async {
      // ensure() is what the player calls before applying a font. It has to
      // consult the custom map first: subtitleFontFileName only knows the ten
      // built-ins, so falling through would report failure and quietly leave
      // the subtitles in the default font.
      final fonts = Directory('${dir.path}/sub_fonts')..createSync();
      File('${fonts.path}/custom_Mine.ttf').writeAsBytesSync(
        File('assets/fonts/Rubik-Regular.ttf').readAsBytesSync(),
      );
      await prefs.setCustomSubtitleFonts({'Mine': 'custom_Mine.ttf'});

      expect(await SubtitleFontService.instance.ensure('Mine'), isTrue);
      expect(SubtitleFontService.instance.registeredForTest, contains('Mine'));
    });

    test('a custom font whose file was deleted is NOT available', () async {
      // The user cleared their Downloads. The pref still names the family, so
      // without this check subtitles would silently render in the default.
      await prefs.setCustomSubtitleFonts({'Kosugi Maru': 'gone.ttf'});
      expect(await SubtitleFontService.instance.isAvailable('Kosugi Maru'), isFalse);
      expect(await SubtitleFontService.instance.ensure('Kosugi Maru'), isFalse);
    });

    test('Default and bundled families are unaffected', () async {
      await prefs.setCustomSubtitleFonts({'Kosugi Maru': 'custom_Kosugi_Maru.ttf'});
      expect(await SubtitleFontService.instance.isAvailable(''), isTrue);
      expect(await SubtitleFontService.instance.isAvailable('Inter'), isTrue);
      expect(await SubtitleFontService.instance.isAvailable('Noto Sans'), isTrue);
    });
  });

  group('removeCustomFont', () {
    test('drops the entry, deletes the file, and clears the selection',
        () async {
      final fonts = Directory('${dir.path}/sub_fonts')..createSync();
      final f = File('${fonts.path}/custom_Kosugi_Maru.ttf')
        ..writeAsBytesSync([0, 1, 2]);
      await prefs.setCustomSubtitleFonts({'Kosugi Maru': 'custom_Kosugi_Maru.ttf'});
      await prefs.setSubtitleFont('Kosugi Maru');

      await SubtitleFontService.instance.removeCustomFont('Kosugi Maru');

      expect(prefs.customSubtitleFonts, isEmpty);
      expect(f.existsSync(), isFalse);
      // Leaving subtitleFont pointing at a font that no longer exists is the
      // silent-failure case this guards.
      expect(prefs.subtitleFont, '');
    });

    test('removing a font that is NOT selected leaves the selection alone',
        () async {
      await prefs.setCustomSubtitleFonts({
        'Kosugi Maru': 'custom_Kosugi_Maru.ttf',
        'Vazirmatn': 'custom_Vazirmatn.ttf',
      });
      await prefs.setSubtitleFont('Vazirmatn');

      await SubtitleFontService.instance.removeCustomFont('Kosugi Maru');

      expect(prefs.customSubtitleFonts.keys, ['Vazirmatn']);
      expect(prefs.subtitleFont, 'Vazirmatn');
    });
  });
  group('addCustomFont', () {
    // Uses a real font so the family comes from the name table, which is what
    // libass matches on. A synthetic file would not prove anything.
    test('takes the family from inside the file, not the filename', () async {
      // Roboto-Regular.ttf really contains the family 'Roboto Flex', which is
      // not one of the built-ins — so this proves the name came from the name
      // table and not from the filename we saved it under.
      final src = '${dir.path}/whatever-i-named-it.ttf';
      File(src).writeAsBytesSync(
        File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync(),
      );

      final family = await SubtitleFontService.instance.addCustomFont(src);

      expect(family, 'Roboto Flex');
      expect(prefs.customSubtitleFonts['Roboto Flex'], 'custom_Roboto_Flex.ttf');
      expect(
        File('${dir.path}/sub_fonts/custom_Roboto_Flex.ttf').existsSync(),
        isTrue,
      );
      expect(await SubtitleFontService.instance.isAvailable('Roboto Flex'), isTrue);
    });

    test('a font whose name clashes with a built-in is renamed', () async {
      // Adding a file whose family is 'Inter' must not shadow the bundled one:
      // two entries with one name make sub-fonts-dir ambiguous.
      final src = '${dir.path}/mine.ttf';
      File(src).writeAsBytesSync(File('assets/fonts/Inter.ttf').readAsBytesSync());

      final family = await SubtitleFontService.instance.addCustomFont(src);

      expect(family, 'Inter (2)');
      expect(prefs.customSubtitleFonts.containsKey('Inter'), isFalse);
    });

    test('the file is copied, so deleting the original does not matter',
        () async {
      final src = File('${dir.path}/temp.ttf')
        ..writeAsBytesSync(File('assets/fonts/Rubik-Regular.ttf').readAsBytesSync());

      await SubtitleFontService.instance.addCustomFont(src.path);
      src.deleteSync();

      expect(await SubtitleFontService.instance.isAvailable('Rubik (2)'), isTrue);
    });

    test('a file that is not a font still works, named after the file',
        () async {
      // No name table to read, so it falls back to the filename stem. The
      // overlay and the native TV player both take the file directly, so it
      // is still usable there even though libass may not match it.
      final src = '${dir.path}/MyFont.ttf';
      File(src).writeAsBytesSync([1, 2, 3, 4, 5]);

      expect(await SubtitleFontService.instance.addCustomFont(src), 'MyFont');
    });

    test('an empty file is refused', () async {
      final src = '${dir.path}/empty.ttf';
      File(src).writeAsBytesSync([]);
      expect(await SubtitleFontService.instance.addCustomFont(src), isNull);
      expect(prefs.customSubtitleFonts, isEmpty);
    });

    test('a missing file is refused rather than throwing', () async {
      expect(
        await SubtitleFontService.instance.addCustomFont('${dir.path}/nope.ttf'),
        isNull,
      );
    });

    test('a custom font is re-registered on the next launch', () async {
      // FontLoader registrations die with the process, so registerCached() has
      // to cover customs too — otherwise the font silently stops applying
      // after a restart and only the overlay shows it.
      final src = '${dir.path}/Rubik-Regular.ttf';
      File(src).writeAsBytesSync(
        File('assets/fonts/Rubik-Regular.ttf').readAsBytesSync(),
      );
      await SubtitleFontService.instance.addCustomFont(src);
      SubtitleFontService.instance.resetForTest();

      await SubtitleFontService.instance.registerCached();

      expect(SubtitleFontService.instance.registeredForTest, contains('Rubik (2)'));
    });

    test('two different fonts can both be added', () async {
      for (final n in ['Lato-Regular.ttf', 'Rubik-Regular.ttf']) {
        final src = '${dir.path}/$n';
        File(src).writeAsBytesSync(File('assets/fonts/$n').readAsBytesSync());
        await SubtitleFontService.instance.addCustomFont(src);
      }
      expect(prefs.customSubtitleFonts.length, 2);
    });
  });
}

class _StyleTestPrefs extends PlaybackPrefs {
  String _color = '#FFFFFFFF';

  @override
  String get subtitleColorHex => _color;

  @override
  Future<void> setSubtitleColorHex(String value) async {
    _color = value;
  }
}
