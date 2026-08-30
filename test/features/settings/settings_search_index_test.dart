import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/settings/settings_search_index.dart';
import 'package:watch_app/l10n/app_localizations_en.dart';
import 'package:watch_app/l10n/app_localizations_fr.dart';

/// Settings pages render their rows inline, so nothing links a new toggle to
/// the search index automatically. This reads the sources and fails when a
/// rendered setting isn't indexed — otherwise the index silently rots and the
/// setting becomes unfindable, which is the bug this feature exists to fix.
///
/// Since the l10n migration the rows read `title: l10n.someKey`, so we resolve
/// each key through `app_en.arb` and compare against the leaves resolved in
/// English. Matching on the English *value* rather than the key keeps the index
/// free of duplicated key names.
final _titleKey = RegExp(r'\btitle: (?:l10n|sheetL10n|context\.l10n)\.(\w+)');

/// Sub-page → the [LeafParent] whose row opens it.
const _pages = {
  'lib/features/settings/settings_playback.dart': LeafParent.playback,
  'lib/features/settings/reader_settings_screen.dart': LeafParent.reader,
  'lib/features/settings/appearance_screen.dart': LeafParent.appearance,
  'lib/features/settings/settings_privacy.dart': LeafParent.privacy,
  'lib/features/settings/settings_storage.dart': LeafParent.storage,
  'lib/features/settings/download_location_screen.dart': LeafParent.downloads,
};

void main() {
  final en = AppLocalizationsEn();
  final arb =
      jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;

  group('settings search index', () {
    test('covers every setting its sub-pages render', () {
      final missing = <String>[];
      for (final entry in _pages.entries) {
        final file = File(entry.key);
        expect(file.existsSync(), isTrue, reason: '${entry.key} moved');
        final indexed = settingsLeaves
            .where((l) => l.parentId == entry.value)
            .map((l) => l.title(en))
            .toSet();
        for (final m in _titleKey.allMatches(file.readAsStringSync())) {
          final key = m.group(1)!;
          final english = arb[key] as String?;
          if (english == null) continue; // not a title string we can resolve
          if (!indexed.contains(english)) {
            missing.add('${entry.value}: $key ("$english")');
          }
        }
      }
      expect(
        missing,
        isEmpty,
        reason:
            'Add these to settingsLeaves in settings_search_index.dart, or '
            'they cannot be found from "Search settings":\n  '
            '${missing.join('\n  ')}',
      );
    });

    test('every leaf names a real category, and resolves to a title', () {
      const known = {
        LeafParent.playback,
        LeafParent.reader,
        LeafParent.appearance,
        LeafParent.privacy,
        LeafParent.storage,
        LeafParent.downloads,
      };
      for (final l in settingsLeaves) {
        expect(known, contains(l.parentId));
        expect(l.title(en).trim(), isNotEmpty);
      }
    });

    // The two reports that started this: "autoplay" only found the Playback
    // folder, and "anime4k" found nothing at all.
    test('finds the settings that used to be unreachable', () {
      Iterable<String> hits(String q) => settingsLeaves
          .where((l) => l.matches(q, en))
          .map((l) => l.title(en));

      expect(hits('autoplay'), contains('Autoplay next episode'));
      expect(hits('autoplay'), contains('Autoplay trailer'));
      expect(hits('anime4k'), contains('Anime4K Enhancement'));
    });

    test('matches synonyms nobody spells out', () {
      Iterable<String> hits(String q) => settingsLeaves
          .where((l) => l.matches(q, en))
          .map((l) => l.title(en));

      expect(hits('pip'), contains('Auto picture-in-picture'));
      expect(hits('scrobble'), contains('Auto-track'));
      expect(hits('oled'), contains('Pure black background'));
    });

    // The whole point of reading titles through l10n: a French user searching
    // French finds the setting, and the result reads in French.
    test('searches and reads in the active language', () {
      final fr = AppLocalizationsFr();
      final autoplay = settingsLeaves.firstWhere(
        (l) => l.title(en) == 'Autoplay next episode',
      );
      expect(autoplay.title(fr), isNot('Autoplay next episode'));
      expect(autoplay.matches(autoplay.title(fr).toLowerCase(), fr), isTrue);
    });
  });
}
