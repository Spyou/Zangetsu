import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/provider/provider_manager.dart';

// Task E4 / Part A: Sozo Read's manga/novel JS contract uses different
// method names than Zangetsu's for three things (chapter list, novel text,
// detail's chapter-list key). These fixtures spin up a REAL QuickJS
// provider (through the same [ProviderManager]/[JsProvider] path every
// installed source uses) so the tests exercise the actual JS wrapper in
// js_bootstrap.dart, not a Dart-side fake.

/// A manga/novel provider shaped exactly like a Sozo Read source: only the
/// Sozo names exist (getChapters/getChapterContent, detail's `chapters`
/// key). getPages uses the name both contracts already share.
const String _sozoShapedJs = r'''
function getPages(chapterUrl) {
  return [{ url: 'https://img/' + chapterUrl, headers: { Referer: 'https://x/' } }];
}
function getChapters(seriesUrl) {
  return [
    { id: 'c1', title: 'Chapter 1', number: 1, url: 'https://x/c1', date: '' }
  ];
}
function getChapterContent(chapterUrl) {
  return { text: 'sozo chapter body for ' + chapterUrl, nextUrl: null };
}
function getDetail(url) {
  return {
    id: 'series1', title: 'Series One', cover: null, url: url,
    description: 'desc', status: 'ongoing', genres: [], authors: [],
    type: 'manga',
    chapters: [
      { id: 'c1', title: 'Chapter 1', number: 1, url: 'https://x/c1', date: '' }
    ]
  };
}
''';

/// A provider shaped like every existing anime JS source: only Zangetsu's
/// primary names exist, PLUS the Sozo fallback names — but the fallback
/// names throw if ever invoked. If the fallback path fires when it
/// shouldn't (e.g. always tries both, or tries the fallback even after a
/// successful primary call), these tests blow up with that thrown message
/// instead of quietly passing.
const String _zangetsuShapedJs = r'''
function getPages(chapterUrl) {
  return [{ url: 'https://img/primary.jpg' }];
}
function getEpisodes(url, opts) {
  return [{ id: 'primary-ep', title: 'Primary Ep', number: 1, url: 'https://x/e1', date: '' }];
}
function getChapters(url) {
  throw new Error('getChapters must never be called -- getEpisodes exists');
}
function getText(chapterUrl) {
  return { html: 'primary text' };
}
function getChapterContent(chapterUrl) {
  throw new Error('getChapterContent must never be called -- getText exists');
}
function getDetail(url) {
  return {
    id: 's1', title: 'S1', url: url, type: 'manga',
    episodes: [{ id: 'primary-ep', title: 'Primary Ep', number: 1, url: 'https://x/e1', date: '' }],
    chapters: [{ id: 'wrong-from-chapters', title: 'Wrong', number: 99, url: 'https://x/wrong', date: '' }]
  };
}
''';

/// A provider whose primary methods exist but genuinely fail (network/parse
/// error, not "method missing"). The fallback names below would happily
/// return valid data if called — proving the fallback logic distinguishes
/// "method not found" from a real provider error only if these tests see
/// the real error surface, not the fallback's data.
const String _genuineErrorJs = r'''
function getEpisodes(url) { throw new Error('network boom'); }
function getChapters(url) { return [{ id: 'c1', title: 'from getChapters', number: 1, url: 'https://x/c1', date: '' }]; }
function getText(chapterUrl) { throw new Error('parse boom'); }
function getChapterContent(chapterUrl) { return { text: 'from getChapterContent' }; }
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderManager manager;

  setUp(() {
    manager = ProviderManager(dio: Dio());
  });

  group('Sozo Read-shaped provider (fallback names only)', () {
    late JsProvider provider;

    setUp(() {
      provider = manager.load(sourceId: 'sozo-fake', jsSource: _sozoShapedJs);
    });

    test('getEpisodes() falls back to getChapters()', () async {
      final eps = await provider.getEpisodes('https://x/series1');
      expect(eps, hasLength(1));
      expect(eps.single.id, 'c1');
      expect(eps.single.title, 'Chapter 1');
    });

    test('getText() falls back to getChapterContent()', () async {
      final t = await provider.getText('https://x/c1');
      expect(t.html, contains('sozo chapter body for https://x/c1'));
    });

    test('getDetail() aliases chapters -> episodes', () async {
      final d = await provider.getDetail('https://x/series1');
      expect(d.episodes, hasLength(1));
      expect(d.episodes.single.id, 'c1');
    });

    test(
      'getPages() still works (a wiring gap, not a name mismatch)',
      () async {
        final pages = await provider.getPages('https://x/c1');
        expect(pages, isNotEmpty);
        expect(pages.single.url, contains('c1'));
      },
    );
  });

  group('Zangetsu-shaped provider (primary names) — anime-safety', () {
    late JsProvider provider;

    setUp(() {
      provider = manager.load(
        sourceId: 'zangetsu-fake',
        jsSource: _zangetsuShapedJs,
      );
    });

    test(
      'getEpisodes() uses getEpisodes(), never reaches getChapters()',
      () async {
        final eps = await provider.getEpisodes('https://x/s1');
        expect(eps.single.id, 'primary-ep');
      },
    );

    test(
      'getText() uses getText(), never reaches getChapterContent()',
      () async {
        final t = await provider.getText('https://x/e1');
        expect(t.html, 'primary text');
      },
    );

    test(
      'getDetail() uses the episodes key, ignores the chapters key',
      () async {
        final d = await provider.getDetail('https://x/s1');
        expect(d.episodes, hasLength(1));
        expect(d.episodes.single.id, 'primary-ep');
      },
    );
  });

  group('fallback never swallows a genuine provider error', () {
    late JsProvider provider;

    setUp(() {
      provider = manager.load(
        sourceId: 'error-fake',
        jsSource: _genuineErrorJs,
      );
    });

    // Provider errors surface as whatever the QuickJS bridge throws for a
    // rejected promise (not necessarily a JsRuntimeException — see
    // provider_manager.dart's fallback comments), so match on the message
    // text via toString() rather than assuming a concrete exception type.
    test(
      'getEpisodes() rethrows a real error instead of falling back',
      () async {
        await expectLater(
          provider.getEpisodes('https://x/s1'),
          throwsA(predicate((e) => e.toString().contains('network boom'))),
        );
      },
    );

    test('getText() rethrows a real error instead of falling back', () async {
      await expectLater(
        provider.getText('https://x/c1'),
        throwsA(predicate((e) => e.toString().contains('parse boom'))),
      );
    });
  });
}
