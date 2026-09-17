import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/di/injector.dart' show sl;
import 'package:watch_app/core/prefs/source_lang_prefs.dart';
import 'package:watch_app/core/ui/source_switcher.dart';

import '../../support/picker_deps.dart';

/// The picker sheet and the Sources screen both read [categorizedSources], so
/// the language filter has to live there — and it has to cover BOTH
/// ecosystems. Aniyomi had no filter at all: choosing English still listed
/// every language.

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('picker_lang');
    Hive.init(dir.path);
    await LangPrefs.initBox('aniyomi_lang_prefs');
  });

  tearDown(() async {
    await disposePickerDeps();
    await sl.reset();
    await Hive.deleteFromDisk();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> enableOnly(Set<String> langs) async {
    final prefs = AnimeLangPrefs();
    await prefs.setEnabled(langs);
    sl.registerSingleton<AnimeLangPrefs>(prefs);
  }

  test('an Aniyomi language you turned off is not offered', () async {
    // One extension, two languages — the case the filter exists for.
    await registerPickerDeps(aniyomi: [
      aniSource(id: 1, name: 'Multi EN', lang: 'en'),
      aniSource(id: 2, name: 'Multi ES', lang: 'es'),
    ]);
    await enableOnly({'en'});

    final ids = categorizedSources().anime.map((r) => r.id).toSet();
    expect(ids, contains('ani:1'));
    expect(ids, isNot(contains('ani:2')), reason: 'Spanish was turned off');
  });

  test('an extension whose ONLY language you turned off still shows', () async {
    // aniSource() gives every source the same pkg, so use a single source:
    // you installed it deliberately, and the picker is the only way to use it.
    await registerPickerDeps(
      aniyomi: [aniSource(id: 3, name: 'Indonesian only', lang: 'id')],
    );
    await enableOnly({'en'});

    final ids = categorizedSources().anime.map((r) => r.id).toSet();
    expect(ids, contains('ani:3'));
  });

  test("'all' is never filtered out", () async {
    await registerPickerDeps(
      aniyomi: [aniSource(id: 4, name: 'Every language', lang: 'all')],
    );
    await enableOnly({'en'});

    expect(
      categorizedSources().anime.map((r) => r.id),
      contains('ani:4'),
    );
  });
}
