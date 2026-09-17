import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/i18n/source_languages.dart';

void main() {
  // defaultSourceLangs reads the device locale via WidgetsBinding.instance.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sourceLangBase', () {
    test('passes a plain base code through', () {
      expect(sourceLangBase('en'), 'en');
      expect(sourceLangBase('ja'), 'ja');
    });

    test('strips region variants (pt-BR → pt, zh-Hans → zh, es_419 → es)', () {
      expect(sourceLangBase('pt-BR'), 'pt');
      expect(sourceLangBase('zh-Hans'), 'zh');
      expect(sourceLangBase('es_419'), 'es');
    });

    test('lower-cases and trims', () {
      expect(sourceLangBase('  EN  '), 'en');
      expect(sourceLangBase('PT-br'), 'pt');
    });

    test('multi/blank sentinels collapse to empty (always-shown)', () {
      expect(sourceLangBase('all'), '');
      expect(sourceLangBase(''), '');
      expect(sourceLangBase('other'), '');
    });
  });

  group('sourceLangVisible', () {
    test('shows a language whose base is enabled, hides one that is not', () {
      expect(sourceLangVisible('en', {'en'}), isTrue);
      expect(sourceLangVisible('es', {'en'}), isFalse);
    });

    test('matches a region variant against its base toggle', () {
      expect(sourceLangVisible('pt-BR', {'pt'}), isTrue);
      expect(sourceLangVisible('pt-BR', {'en'}), isFalse);
    });

    test('always shows multi-language / blank entries, even with none enabled',
        () {
      expect(sourceLangVisible('all', <String>{}), isTrue);
      expect(sourceLangVisible('', {'en'}), isTrue);
    });

    test('always shows a language the picker cannot toggle (not in the map)',
        () {
      // A code with no entry in kSourceLanguages has no toggle in the picker,
      // so hiding it would strand the source with no way to get it back.
      //
      // Deliberately a code that cannot become real: this used to say 'eo',
      // which stopped being unknown the day Esperanto was added to the map,
      // and the test then failed for a year without meaning anything.
      expect(sourceLangVisible('zz', {'en'}), isTrue);
      expect(kSourceLanguages.containsKey('zz'), isFalse,
          reason: 'the example has to stay genuinely unknown');
    });
  });

  group('sortedSourceLangCodes', () {
    test('lists English first and only known codes', () {
      final codes = sortedSourceLangCodes();
      expect(codes.first, 'en');
      expect(codes.toSet(), kSourceLanguages.keys.toSet());
      expect(codes.length, kSourceLanguages.length);
    });
  });

  group('sourceLangLabel', () {
    test('maps a known code, falls back to the raw code otherwise', () {
      expect(sourceLangLabel('en'), 'English');
      expect(sourceLangLabel('ja'), 'Japanese');
      // Same reasoning as above — an example that cannot quietly become known.
      expect(sourceLangLabel('zz'), 'zz');
    });
  });

  group('defaultSourceLangs', () {
    test('always includes English', () {
      expect(defaultSourceLangs(), contains('en'));
    });
  });
}
