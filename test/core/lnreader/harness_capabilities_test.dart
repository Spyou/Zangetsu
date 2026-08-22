import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';

/// LNReader plugins are written for React Native, which hands them a
/// browser-ish environment for free. This runtime is QuickJS, which ships
/// almost none of it — so every global a plugin assumes has to be polyfilled
/// in the bundle or the harness. Each gap has cost a real, hard-to-read bug
/// ("source isn't responding" for a missing require; a silent
/// "decryption error" for a missing TextEncoder), so they're pinned here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late JavascriptRuntime rt;

  setUpAll(() async {
    final bundle = await rootBundle.loadString('assets/js/lnreader_cheerio.js');
    final harness = await rootBundle.loadString('assets/js/lnreader_harness.js');
    rt = getJavascriptRuntime(xhr: false);
    expect(rt.evaluate(bundle).isError, isFalse);
    expect(rt.evaluate(harness).isError, isFalse);
  });

  String eval(String js) {
    final r = rt.evaluate(js);
    expect(r.isError, isFalse, reason: js);
    return r.stringResult;
  }

  test('every module a plugin can require() resolves', () {
    for (final m in const [
      'cheerio', 'htmlparser2', 'dayjs',
      '@libs/fetch', '@libs/novelStatus', '@libs/defaultCover',
      '@libs/isAbsoluteUrl', '@libs/storage', '@libs/filterInputs',
      '@libs/aes', '@/types/constants',
    ]) {
      // dayjs is a function, the rest are objects — all that matters is that
      // the resolver knows the name and doesn't throw 'unknown module'.
      expect(eval("typeof __require('$m')"), isNot('undefined'), reason: m);
    }
  });

  test('@/types/constants carries what the newer plugins read off it', () {
    expect(eval("__require('@/types/constants').NovelStatus.Ongoing"), 'Ongoing');
    expect(eval("typeof __require('@/types/constants').defaultCover"), 'string');
  });

  test('storage stubs have the get/set shape, not a bare object', () {
    // RLIB called localStorage.get() at load time and died on {}.
    for (final s in const ['storage', 'localStorage', 'sessionStorage']) {
      expect(eval("typeof __require('@libs/storage').$s.get"), 'function');
      expect(eval("typeof __require('@libs/storage').$s.set"), 'function');
    }
  });

  test('browser globals plugins assume are present', () {
    for (final g in const ['TextEncoder', 'TextDecoder', 'FormData', 'fetch',
                           'Buffer', 'atob', 'btoa', 'URL', 'URLSearchParams']) {
      expect(eval('typeof $g'), 'function', reason: g);
    }
  });

  test('TextEncoder/TextDecoder handle multi-byte UTF-8', () {
    expect(eval("Array.from(new TextEncoder().encode('h\\u00e9')).join(',')"),
        '104,195,169');
    expect(eval("new TextDecoder().decode(new Uint8Array([104,195,169]))"), 'hé');
  });

  test('URL exposes searchParams and resolves against a base', () {
    expect(eval("new URL('https://a.b/c?d=7&e=8').searchParams.get('e')"), '8');
    expect(eval("new URL('/x','https://a.b/c/d').href"), 'https://a.b/x');
  });

  test('response headers are readable, and case-insensitively', () {
    // Sites and plugins disagree on capitalisation of the same header —
    // 'X-WP-TotalPages' and 'X-Wp-Totalpages' both appear in the catalogue.
    // Six sources either break outright or silently truncate their chapter
    // list when this reads null.
    expect(
      eval(
        "var h = __headers({'Content-Type':'application/json','X-WP-TotalPages':'12'});"
        "[h.get('content-type'), h.get('Content-Type'),"
        " h.get('x-wp-totalpages'), h.get('X-WP-TotalPages'),"
        " String(h.get('nope')), String(h.has('X-Wp-TotalPages'))].join('|');",
      ),
      'application/json|application/json|12|12|null|true',
    );
  });

  test('a response with no headers reads null instead of throwing', () {
    expect(eval("String(__headers(undefined).get('content-type'))"), 'null');
    expect(eval("String(__headers({}).get('content-type'))"), 'null');
  });

  test('AES-GCM decrypts what it encrypts, the way WTR-LAB drives it', () {
    expect(
      eval("""
        var key = new TextEncoder().encode('0123456789abcdef0123456789abcdef');
        var c = globalThis.__aesGcm(key, new Uint8Array(12));
        new TextDecoder().decode(c.decrypt(c.encrypt(new TextEncoder().encode('{"ok":true}'))));
      """),
      '{"ok":true}',
    );
  });
}
