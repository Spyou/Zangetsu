import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/repository/source_actions.dart';

/// "Open in browser" shows ONE page — the chapter you're on — on the source's
/// own site.
///
/// Mihon and Aniyomi hand back an OPAQUE chapter key, not a URL. Requiring an
/// absolute link hid the row on every Mihon source, which is the entire set it
/// was built for — so a relative key is joined to the source's base URL.
///
/// No SourceRepository is registered here, so [webViewUrlFor] returns null and
/// the relative cases resolve to null. That is the point: these assert what
/// survives WITHOUT a base URL, and the scheme guard is the part that must
/// hold either way.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('resolveChapterWebUrl', resolveFallbackTests);

  test('an absolute chapter link is used as-is', () {
    expect(
      chapterWebUrl('mihon:1', 'https://asurascans.com/comics/x/chapter-110'),
      'https://asurascans.com/comics/x/chapter-110',
    );
    expect(
      chapterWebUrl('mihon:1', 'http://example.org/c/1'),
      'http://example.org/c/1',
    );
  });

  test('surrounding whitespace does not decide it', () {
    expect(
      chapterWebUrl('mihon:1', '  https://a.test/c/1  '),
      'https://a.test/c/1',
    );
  });

  test('a non-web scheme is refused, base URL or not', () {
    // A chapter key comes from a third-party extension; none of these should
    // ever reach a WebView.
    expect(chapterWebUrl('mihon:1', 'javascript:alert(1)'), isNull);
    expect(chapterWebUrl('mihon:1', 'file:///etc/passwd'), isNull);
    expect(chapterWebUrl('mihon:1', 'intent://x#Intent;end'), isNull);
    expect(canOpenInBrowser('mihon:1', 'javascript:alert(1)'), isFalse);
  });

  test('empty is not a link', () {
    expect(chapterWebUrl('mihon:1', ''), isNull);
    expect(chapterWebUrl('mihon:1', '   '), isNull);
    expect(canOpenInBrowser('mihon:1', ''), isFalse);
  });

  test('a relative key with no base URL yields nothing to open', () {
    // Better a hidden row than a button that opens a blank page.
    expect(chapterWebUrl('mihon:1', '/manga/123/chapter/4'), isNull);
    expect(canOpenInBrowser('mihon:1', '/manga/123/chapter/4'), isFalse);
  });

  test('opening a non-link is a no-op rather than a crash', () async {
    await openUrlInSourceWebView('');
    await openUrlInSourceWebView('not-a-url');
  });

  group('joinChapterUrl — the relative-key join, with a base in hand', () {
    const base = 'https://asurascans.com';

    test('a leading-slash key is appended to the base', () {
      expect(
        joinChapterUrl(base, '/series/surviving/chapter-110'),
        'https://asurascans.com/series/surviving/chapter-110',
      );
    });

    test('a key with no leading slash still gets one', () {
      expect(
        joinChapterUrl(base, 'series/x/ch-1'),
        'https://asurascans.com/series/x/ch-1',
      );
    });

    test('a trailing slash on the base never doubles up', () {
      expect(joinChapterUrl('https://a.test/', '/c/1'), 'https://a.test/c/1');
      expect(joinChapterUrl('https://a.test///', '/c/1'), 'https://a.test/c/1');
      expect(joinChapterUrl('https://a.test/', 'c/1'), 'https://a.test/c/1');
    });

    test('an absolute key ignores the base entirely', () {
      expect(
        joinChapterUrl(base, 'https://elsewhere.test/c/9'),
        'https://elsewhere.test/c/9',
      );
    });

    test('a dangerous scheme is still refused even with a base', () {
      expect(joinChapterUrl(base, 'javascript:alert(1)'), isNull);
      expect(joinChapterUrl(base, 'file:///etc/passwd'), isNull);
    });

    test('a blank base leaves nothing to join to', () {
      expect(joinChapterUrl(null, '/c/1'), isNull);
      expect(joinChapterUrl('', '/c/1'), isNull);
      expect(joinChapterUrl('   ', '/c/1'), isNull);
    });
  });
}

/// [resolveChapterWebUrl] asks the SOURCE where the chapter lives instead of
/// gluing its stored key onto the base URL.
///
/// The reason is Asura: it stores `/series/<slug>` because its real slugs carry
/// a rotating hash, and overrides the extension-side URL methods to build the
/// real `/comics/<slug>-<hash>` page. Joining by hand lands on a 404 there —
/// verified against the live site while fixing this.
///
/// These assert the SAFETY half: every path where the source cannot answer must
/// fall back to exactly what [chapterWebUrl] returned before this existed.
void resolveFallbackTests() {
  const channel = MethodChannel('zangetsu/mihon');

  void nativeReturns(Object? value, {bool throwIt = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'webUrl') return null;
          if (throwIt) throw PlatformException(code: 'NO_SOURCE');
          return value;
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a non-Mihon source never asks, and keeps the old join', () async {
    nativeReturns('https://should-not-be-used.test/x');
    expect(
      await resolveChapterWebUrl('ani:1', 'https://real.test/c/1'),
      'https://real.test/c/1',
    );
  });

  test('the source answer wins for a Mihon source', () async {
    nativeReturns('https://asurascans.com/comics/slug-6f7fe6eb/chapter/12');
    expect(
      await resolveChapterWebUrl('mihon:1', '/series/slug'),
      'https://asurascans.com/comics/slug-6f7fe6eb/chapter/12',
    );
  });

  test('a source that cannot answer falls back, it does not fail', () async {
    nativeReturns(null);
    expect(
      await resolveChapterWebUrl('mihon:1', 'https://real.test/c/1'),
      'https://real.test/c/1',
    );
  });

  test('a native error falls back rather than throwing', () async {
    nativeReturns(null, throwIt: true);
    expect(
      await resolveChapterWebUrl('mihon:1', 'https://real.test/c/1'),
      'https://real.test/c/1',
    );
  });

  test(
    'a non-http answer is refused, exactly like the join refuses one',
    () async {
      // The string comes from a third-party extension; javascript:/intent: must
      // never reach a browser just because the source said so.
      nativeReturns('javascript:alert(1)');
      expect(
        await resolveChapterWebUrl('mihon:1', 'https://real.test/c/1'),
        'https://real.test/c/1',
      );
    },
  );

  test('an unparseable mihon id falls back', () async {
    nativeReturns('https://should-not-be-used.test/x');
    expect(
      await resolveChapterWebUrl('mihon:abc', 'https://real.test/c/1'),
      'https://real.test/c/1',
    );
  });
}
