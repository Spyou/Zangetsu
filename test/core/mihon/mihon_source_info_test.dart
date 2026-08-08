import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mihon/mihon_source_info.dart';

void main() {
  group('MihonSourceInfo.fromJson', () {
    test('parses all 9 keys when present', () {
      final info = MihonSourceInfo.fromJson(const {
        'id': 42,
        'name': 'MangaDex',
        'lang': 'en',
        'baseUrl': 'https://mangadex.org',
        'pkg': 'eu.kanade.tachiyomi.extension.en.mangadex',
        'nsfw': true,
        'version': '2.1.0',
        'versionCode': 7,
        'headers': {'Referer': 'https://mangadex.org/'},
      });
      expect(info.id, 42);
      expect(info.name, 'MangaDex');
      expect(info.lang, 'en');
      expect(info.baseUrl, 'https://mangadex.org');
      expect(info.pkg, 'eu.kanade.tachiyomi.extension.en.mangadex');
      expect(info.nsfw, isTrue);
      expect(info.version, '2.1.0');
      expect(info.versionCode, 7);
      expect(info.headers, {'Referer': 'https://mangadex.org/'});
    });

    test('defaults to empty version + 0 code + empty headers when keys absent', () {
      final info = MihonSourceInfo.fromJson(const {
        'id': 7,
        'name': 'Source',
        'lang': 'en',
        'baseUrl': 'https://source.test',
        'pkg': 'x.y.z',
        'nsfw': false,
      });
      expect(info.version, '');
      expect(info.versionCode, 0);
      expect(info.headers, isEmpty);
    });

    test('id survives a large 64-bit value without truncation', () {
      // Source.id is a Kotlin Long derived from an MD5 hash — routinely far
      // outside the 32-bit int range. Distinguishes int-vs-double coercion:
      // an accidental double round-trip through JSON would still compare
      // equal here, but a lossy int32 truncation would not.
      final info = MihonSourceInfo.fromJson(const {
        'id': 8924691234567890123,
        'name': 'Big Id',
        'lang': 'en',
        'baseUrl': '',
        'pkg': 'x',
        'nsfw': false,
      });
      expect(info.id, 8924691234567890123);
    });
  });
}
