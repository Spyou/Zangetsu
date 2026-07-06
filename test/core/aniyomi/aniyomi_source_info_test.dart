import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_source_info.dart';

void main() {
  group('AniyomiSourceInfo.fromJson version fields', () {
    test('parses version + versionCode when present', () {
      final info = AniyomiSourceInfo.fromJson(const {
        'id': 7,
        'name': 'HiAnime',
        'lang': 'en',
        'baseUrl': 'https://hianime.to',
        'pkg': 'eu.kanade.tachiyomi.animeextension.en.hianime',
        'nsfw': false,
        'version': '1.4.21',
        'versionCode': 21,
      });
      expect(info.version, '1.4.21');
      expect(info.versionCode, 21);
    });

    test('defaults to empty version + 0 code when keys absent', () {
      final info = AniyomiSourceInfo.fromJson(const {
        'id': 7,
        'name': 'HiAnime',
        'lang': 'en',
        'baseUrl': 'https://hianime.to',
        'pkg': 'x.y.z',
        'nsfw': false,
      });
      expect(info.version, '');
      expect(info.versionCode, 0);
    });
  });
}
