import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/mihon/mihon_provider.dart';
import 'package:watch_app/core/mihon/mihon_source_info.dart';
import 'package:watch_app/core/models/provider_info.dart';

/// Channel-surface tests for [MihonProvider].
///
/// This is the M6 regression net for the documented anime/manga divergence:
/// chapter listing goes out over `getChapters`, NOT `getEpisodes` — the
/// Dart-side method is named `getEpisodes` (required by [BaseProvider]) but
/// must invoke the native `getChapters` method. A typo'd/copy-pasted method
/// name here compiles fine and only fails on-device at runtime, so every
/// assertion below checks the real `MethodCall.method` and
/// `MethodCall.arguments` against `MihonBridge.kt`, not just "did not throw".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zangetsu/mihon');
  final log = <MethodCall>[];

  void install(Future<dynamic> Function(MethodCall call) handler) {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      return handler(call);
    });
  }

  tearDown(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  MihonSourceInfo srcInfo({
    int id = 7,
    String name = 'MangaSrc',
    String lang = 'en',
    String baseUrl = 'https://m.example.com',
    Map<String, String> headers = const {},
  }) =>
      MihonSourceInfo(
        id: id,
        name: name,
        lang: lang,
        baseUrl: baseUrl,
        pkg: 'com.test.manga',
        nsfw: false,
        headers: headers,
        version: '2.3',
        versionCode: 9,
      );

  group('identity', () {
    test('sourceId is namespaced mihon:<id>, not ani:<id>', () {
      final p = MihonProvider(info: srcInfo(id: 42));
      expect(p.sourceId, 'mihon:42');
      expect(p.sourceId, isNot('ani:42'));
    });

    test('getInfo returns ProviderType.manga with the source metadata',
        () async {
      final p = MihonProvider(
        info: srcInfo(name: 'Mangalib', lang: 'fr', baseUrl: 'https://x.test'),
      );
      final info = await p.getInfo();
      expect(info.type, ProviderType.manga);
      expect(info.name, 'Mangalib');
      expect(info.lang, 'fr');
      expect(info.baseUrl, 'https://x.test');
    });
  });

  group('getEpisodes → native getChapters (the M6 trap)', () {
    test(
        'invokes "getChapters", never "getEpisodes", with sourceId/url, and '
        'normalises the newest-first reply to chronological order', () async {
      install((call) async {
        if (call.method == 'getChapters') {
          // Source replies newest-first (the real Tachiyomi/Mihon convention)
          // — chapter 1100 before chapter 1099.
          return jsonEncode([
            {
              'url': '/manga/one-piece/c1100',
              'name': 'Chapter 1100',
              'chapter_number': 1100.0,
              'date_upload': 1700000000000,
              'scanlator': 'TCB',
            },
            {
              'url': '/manga/one-piece/c1099',
              'name': 'Chapter 1099',
              'chapter_number': 1099.0,
            },
          ]);
        }
        return null;
      });
      final p = MihonProvider(info: srcInfo(id: 7));
      final chapters = await p.getEpisodes('/manga/one-piece');

      expect(log, hasLength(1));
      expect(log.single.method, 'getChapters');
      expect(log.single.method, isNot('getEpisodes'));
      final args = log.single.arguments as Map;
      expect(args['sourceId'], 7);
      expect(args['url'], '/manga/one-piece');

      // sortChaptersAscending must have run: chronological (1099 then 1100),
      // not the wire order (1100 then 1099) the fixture above sent.
      expect(chapters, hasLength(2));
      expect(chapters[0].number, 1099.0);
      expect(chapters[0].title, 'Chapter 1099');
      expect(chapters[1].number, 1100.0);
      expect(chapters[1].title, 'Chapter 1100');
      expect(chapters[1].url, '/manga/one-piece/c1100');
      // scanlator is folded into the id (mihon_mapping.dart), not displayed.
      expect(chapters[1].id, 'ch-1100.0-TCB');
    });

    test('a channel call to the wrong method name would leave chapters empty',
        () async {
      // Regression guard: if getEpisodes ever called "getEpisodes" on the
      // channel instead of "getChapters", this mock (which only answers
      // getChapters) would return null and the list would come back empty.
      // isEmpty alone wouldn't catch a renamed call (null decodes to []
      // either way) — it's the method-name assertion below that's load-bearing.
      install((call) async => call.method == 'getChapters' ? '[]' : null);
      final p = MihonProvider(info: srcInfo());
      final chapters = await p.getEpisodes('/x');
      expect(chapters, isEmpty);
      expect(log.single.method, 'getChapters');
    });
  });

  group('getDetail', () {
    test('fetches getDetails + getChapters in parallel and merges them',
        () async {
      install((call) async {
        switch (call.method) {
          case 'getDetails':
            return jsonEncode({
              'url': '/manga/one-piece',
              'title': 'One Piece',
              'thumbnail_url': 'https://cdn.example.com/op.jpg',
              'description': 'Pirates.',
              'status': 1,
              'genre': 'Action, Adventure',
            });
          case 'getChapters':
            return jsonEncode([
              {'url': '/c1', 'name': 'Chapter 1', 'chapter_number': 1.0},
            ]);
          default:
            return null;
        }
      });
      final p = MihonProvider(info: srcInfo(id: 7));
      final detail = await p.getDetail('/manga/one-piece');

      final methods = log.map((c) => c.method).toSet();
      expect(methods, {'getDetails', 'getChapters'});
      for (final call in log) {
        final args = call.arguments as Map;
        expect(args['sourceId'], 7);
        expect(args['url'], '/manga/one-piece');
      }

      expect(detail.title, 'One Piece');
      expect(detail.type, ProviderType.manga);
      expect(detail.sourceId, 'mihon:7');
      expect(detail.episodes, hasLength(1));
      expect(detail.episodes.single.title, 'Chapter 1');
    });
  });

  group('search', () {
    test('forwards query/page and only includes filters when non-empty',
        () async {
      install((call) async => call.method == 'search' ? '[]' : null);
      final p = MihonProvider(info: srcInfo(id: 3));

      await p.search('luffy', 2);
      expect(log.single.method, 'search');
      var args = log.single.arguments as Map;
      expect(args['sourceId'], 3);
      expect(args['query'], 'luffy');
      expect(args['page'], 2);
      expect(args.containsKey('filters'), isFalse);

      await p.search('luffy', 1, filtersJson: '[{"type":"header"}]');
      args = log.last.arguments as Map;
      expect(args['filters'], '[{"type":"header"}]');
    });
  });

  group('getPages — one unresolvable page must not fail the chapter', () {
    test('drops the page with a null imageUrl, keeps the resolvable ones',
        () async {
      install((call) async {
        if (call.method == 'getPages') {
          return jsonEncode([
            {
              'index': 0,
              'url': '/c1/p1',
              'imageUrl': 'https://cdn.example.com/p1.jpg',
              'headers': {'Referer': 'https://m.example.com'},
            },
            {
              // Resolution genuinely failed for this one page server-side.
              'index': 1,
              'url': '/c1/p2',
              'imageUrl': null,
              'headers': <String, dynamic>{},
            },
            {
              'index': 2,
              'url': '/c1/p3',
              'imageUrl': 'https://cdn.example.com/p3.jpg',
            },
          ]);
        }
        return null;
      });
      final p = MihonProvider(info: srcInfo(id: 7));
      final pages = await p.getPages('/c1');

      expect(log.single.method, 'getPages');
      final args = log.single.arguments as Map;
      expect(args['sourceId'], 7);
      expect(args['url'], '/c1');

      // 3 pages sent, only the 2 resolvable ones survive — the bad page did
      // NOT fail the whole chapter.
      expect(pages, hasLength(2));
      expect(pages[0].url, 'https://cdn.example.com/p1.jpg');
      expect(pages[0].headers, {'Referer': 'https://m.example.com'});
      expect(pages[1].url, 'https://cdn.example.com/p3.jpg');
    });

    test('malformed getPages reply degrades to an empty list', () async {
      install((call) async => call.method == 'getPages' ? 'not json' : null);
      final p = MihonProvider(info: srcInfo());
      expect(await p.getPages('/c1'), isEmpty);
    });
  });

  group('getVideoSources — reading provider, no video leaf', () {
    test('always returns [] and never touches the channel', () async {
      install((call) async {
        fail('MihonProvider.getVideoSources must not call the platform channel');
      });
      final p = MihonProvider(info: srcInfo());
      final result = await p.getVideoSources('/c1');
      expect(result, isEmpty);
      expect(log, isEmpty);
    });
  });

  group('getText — manga-only, novels stay on the JS path', () {
    test('throws UnsupportedError', () async {
      final p = MihonProvider(info: srcInfo());
      expect(() => p.getText('/c1'), throwsUnsupportedError);
    });
  });

  group('cover headers — Referer fallback for header-locked image hosts', () {
    test('injects Referer=baseUrl when the source sets none', () async {
      install((call) async {
        if (call.method == 'getPopular') {
          return jsonEncode([
            {'url': '/m1', 'title': 'Manga One', 'thumbnail_url': 'https://cdn/m1.jpg'},
          ]);
        }
        return null;
      });
      final p = MihonProvider(
        info: srcInfo(baseUrl: 'https://m.example.com', headers: const {}),
      );
      final items = await p.popular();
      expect(items.single.coverHeaders, {'Referer': 'https://m.example.com'});
    });

    test('leaves an existing Referer untouched (case-insensitive)', () async {
      install((call) async {
        if (call.method == 'getPopular') {
          return jsonEncode([
            {'url': '/m1', 'title': 'Manga One'},
          ]);
        }
        return null;
      });
      final p = MihonProvider(
        info: srcInfo(
          baseUrl: 'https://m.example.com',
          headers: const {'referer': 'https://original.example.com'},
        ),
      );
      final items = await p.popular();
      expect(items.single.coverHeaders, {'referer': 'https://original.example.com'});
    });

    test('no headers and no baseUrl → coverHeaders is null', () async {
      install((call) async {
        if (call.method == 'getPopular') {
          return jsonEncode([
            {'url': '/m1', 'title': 'Manga One'},
          ]);
        }
        return null;
      });
      final p = MihonProvider(info: srcInfo(baseUrl: '', headers: const {}));
      final items = await p.popular();
      expect(items.single.coverHeaders, isNull);
    });
  });
}
