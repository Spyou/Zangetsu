import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/features/settings/settings_search_index.dart';

/// Settings pages render their rows inline, so nothing links a new toggle to
/// the search index automatically. This reads the sources and fails when a
/// rendered setting isn't indexed — otherwise the index silently rots and the
/// setting becomes unfindable, which is the bug this feature exists to fix.
///
/// `\b` keeps `subtitle:` out: in "subtitle:" there's no word boundary between
/// the "b" and the "title", so only a real `title:` field matches.
final _titleField = RegExp(r"\btitle: '([^']+)'");

/// Sub-page → the category row that opens it.
const _pages = {
  'lib/features/settings/settings_playback.dart': 'Playback',
  'lib/features/settings/reader_settings_screen.dart': 'Reader',
  'lib/features/settings/appearance_screen.dart': 'Appearance',
  'lib/features/settings/settings_privacy.dart': 'Privacy',
  'lib/features/settings/settings_storage.dart': 'Storage',
  'lib/features/settings/download_location_screen.dart': 'Downloads',
};

void main() {
  group('settings search index', () {
    test('covers every setting its sub-pages render', () {
      final missing = <String>[];
      for (final entry in _pages.entries) {
        final file = File(entry.key);
        expect(file.existsSync(), isTrue, reason: '${entry.key} moved');
        final indexed = settingsLeaves
            .where((l) => l.parent == entry.value)
            .map((l) => l.title)
            .toSet();
        for (final m in _titleField.allMatches(file.readAsStringSync())) {
          final title = m.group(1)!;
          if (!indexed.contains(title)) missing.add('${entry.value}: $title');
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

    test('every leaf names a category, and none is blank', () {
      for (final l in settingsLeaves) {
        expect(l.title.trim(), isNotEmpty);
        expect(l.parent.trim(), isNotEmpty);
      }
    });

    // The two reports that started this: "autoplay" only found the Playback
    // folder, and "anime4k" found nothing at all.
    test('finds the settings that used to be unreachable', () {
      Iterable<String> hits(String q) =>
          settingsLeaves.where((l) => l.matches(q)).map((l) => l.title);

      expect(hits('autoplay'), contains('Autoplay next episode'));
      expect(hits('autoplay'), contains('Autoplay trailer'));
      expect(hits('anime4k'), contains('Anime4K Enhancement'));
    });

    test('matches synonyms nobody spells out', () {
      Iterable<String> hits(String q) =>
          settingsLeaves.where((l) => l.matches(q)).map((l) => l.title);

      expect(hits('pip'), contains('Auto picture-in-picture'));
      expect(hits('scrobble'), contains('Auto-track'));
      expect(hits('oled'), contains('Pure black background'));
    });
  });
}
