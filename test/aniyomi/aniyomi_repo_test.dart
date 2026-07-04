import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/aniyomi/aniyomi_extension_service.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------------
  // AniyomiRepo.parseIndex
  // ---------------------------------------------------------------------------
  group('AniyomiRepo.parseIndex', () {
    test('parses index.min.json entries + builds apk url', () {
      const json = '''
      [{"name":"HiAnime","pkg":"eu.kanade.tachiyomi.animeextension.en.hianime",
        "apk":"hianime-v1.4.5.apk","lang":"en","code":14,"version":"1.4.5","nsfw":0,
        "sources":[{"id":123,"lang":"en","name":"HiAnime","baseUrl":"https://hianime.to"}]}]''';
      final entries =
          AniyomiRepo.parseIndex(json, repoBaseUrl: 'https://x.dev/repo');
      expect(entries, hasLength(1));
      expect(entries.first.sources.first.id, 123);
      expect(
          entries.first.apkUrl, 'https://x.dev/repo/apk/hianime-v1.4.5.apk');
      expect(entries.first.nsfw, false);
    });

    test('nsfw int 1 maps to bool true', () {
      const json =
          '[{"name":"A","pkg":"p","apk":"a.apk","lang":"en","code":1,"version":"1.0","nsfw":1,"sources":[]}]';
      final entries =
          AniyomiRepo.parseIndex(json, repoBaseUrl: 'https://x.dev/repo');
      expect(entries, hasLength(1));
      expect(entries.first.nsfw, true);
    });

    test('nsfw int 0 maps to bool false', () {
      const json =
          '[{"name":"B","pkg":"q","apk":"b.apk","lang":"en","code":2,"version":"1.0","nsfw":0,"sources":[]}]';
      final entries =
          AniyomiRepo.parseIndex(json, repoBaseUrl: 'https://x.dev/repo');
      expect(entries.first.nsfw, false);
    });

    test('malformed entry is skipped without throwing', () {
      // "apk":123 is an int, not a String — the cast fails and the entry is
      // skipped; the valid second entry is still parsed.
      const json = '''[
        {"name":"bad","pkg":"x","apk":123,"lang":"en","code":"oops","version":"1.0","nsfw":0,"sources":"not-a-list"},
        {"name":"Good","pkg":"com.good","apk":"good.apk","lang":"en","code":5,"version":"1.0","nsfw":0,"sources":[]}
      ]''';
      expect(
        () => AniyomiRepo.parseIndex(json, repoBaseUrl: 'https://x.dev/repo'),
        returnsNormally,
      );
    });

    test('totally malformed JSON returns empty list without throwing', () {
      final entries =
          AniyomiRepo.parseIndex('not json at all', repoBaseUrl: 'https://x.dev/repo');
      expect(entries, isEmpty);
    });

    test('empty JSON array returns empty list', () {
      final entries = AniyomiRepo.parseIndex('[]', repoBaseUrl: 'https://x.dev/repo');
      expect(entries, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // AniyomiExtensionService.listSources via mocked MethodChannel
  // ---------------------------------------------------------------------------
  group('AniyomiExtensionService.listSources', () {
    const channel = MethodChannel('zangetsu/aniyomi');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'listSources') {
          return jsonEncode([
            {
              'id': 456,
              'name': 'TestSource',
              'lang': 'en',
              'nsfw': false,
              'pkg': 'com.test.source',
              'baseUrl': 'https://test.example.com',
            }
          ]);
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('decodes JSON string into AniyomiSourceInfo list', () async {
      final service = AniyomiExtensionService();
      final sources = await service.listSources();
      expect(sources, hasLength(1));
      expect(sources.first.id, 456);
      expect(sources.first.name, 'TestSource');
      expect(sources.first.lang, 'en');
      expect(sources.first.nsfw, false);
      expect(sources.first.pkg, 'com.test.source');
      expect(sources.first.baseUrl, 'https://test.example.com');
    });

    test('returns empty list when channel returns null', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      final service = AniyomiExtensionService();
      final sources = await service.listSources();
      expect(sources, isEmpty);
    });
  });
}
