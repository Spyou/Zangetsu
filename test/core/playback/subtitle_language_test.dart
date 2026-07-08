import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/playback/subtitle_language.dart';
import 'package:watch_app/core/models/video_source.dart';

Language _lang(String iso1) => languageByPref(iso1)!;
Subtitle _sub(String lang, [String? label]) =>
    Subtitle(url: 'u', lang: lang, label: label);

void main() {
  group('matchesSourceLang — broadened', () {
    test('English name / iso1 / iso2, decorated', () {
      final en = _lang('en');
      expect(matchesSourceLang('English', en), isTrue);
      expect(matchesSourceLang('en', en), isTrue);
      expect(matchesSourceLang('eng', en), isTrue);
      expect(matchesSourceLang('English (SDH)', en), isTrue);
      expect(matchesSourceLang('English (CR)', en), isTrue);
    });
    test('native names', () {
      expect(matchesSourceLang('Français', _lang('fr')), isTrue);
      expect(matchesSourceLang('Español', _lang('es')), isTrue);
      expect(matchesSourceLang('हिन्दी', _lang('hi')), isTrue);
      expect(matchesSourceLang('日本語', _lang('ja')), isTrue);
      expect(matchesSourceLang('Deutsch', _lang('de')), isTrue);
    });
    test('ISO 639-2/T variant codes', () {
      expect(matchesSourceLang('fra', _lang('fr')), isTrue); // /T
      expect(matchesSourceLang('fre', _lang('fr')), isTrue); // /B still
      expect(matchesSourceLang('deu', _lang('de')), isTrue);
      expect(matchesSourceLang('zho', _lang('zh')), isTrue);
    });
    test('regional / descriptive aliases', () {
      expect(matchesSourceLang('Brazilian', _lang('pt')), isTrue);
      expect(matchesSourceLang('Brazilian Portuguese', _lang('pt')), isTrue);
      expect(matchesSourceLang('Farsi', _lang('fa')), isTrue);
      expect(matchesSourceLang('Simplified', _lang('zh')), isTrue);
      expect(matchesSourceLang('Latino', _lang('es')), isTrue);
    });
    test('region-suffixed codes tokenise', () {
      expect(matchesSourceLang('pt-BR', _lang('pt')), isTrue);
      expect(matchesSourceLang('fr-FR', _lang('fr')), isTrue);
    });
    test('additive: a code glued to a digit still tokenises to the code', () {
      expect(matchesSourceLang('en2', _lang('en')), isTrue);
    });
    test('whole-token safety — no substring false matches', () {
      expect(matchesSourceLang('Bengali', _lang('en')), isFalse); // eng/en
      expect(matchesSourceLang('Marathi', _lang('ar')), isFalse); // ar
      expect(matchesSourceLang('', _lang('en')), isFalse);
    });
  });

  group('languageOfSource', () {
    test('resolves a source label to its Language', () {
      expect(languageOfSource('Français')?.iso1, 'fr');
      expect(languageOfSource('eng')?.iso1, 'en');
      expect(languageOfSource('Brazilian')?.iso1, 'pt');
      expect(languageOfSource('totally-unknown'), isNull);
    });
  });

  group('pickPreferredSub', () {
    test('matches by lang, then by label; first wins; null when none', () {
      final fr = _lang('fr');
      expect(pickPreferredSub([_sub('English'), _sub('French')], fr)?.lang,
          'French');
      // language in label, code in lang
      expect(pickPreferredSub([_sub('xx', 'Français')], fr)?.label, 'Français');
      expect(pickPreferredSub([_sub('English'), _sub('German')], fr), isNull);
      expect(pickPreferredSub(const <Subtitle>[], fr), isNull);
    });
  });
}
