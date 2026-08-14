import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:watch_app/core/aniyomi/aniyomi_repo.dart';
import 'package:watch_app/core/mihon/mihon_repo.dart';

/// Both fixtures were downloaded from the live keiyoushi repo on 2026-08-05
/// and are committed verbatim:
///
/// * `keiyoushi_index.json`     — the real Mihon index (1,369 extensions)
/// * `keiyoushi_index_min.json` — the legacy array keiyoushi still serves,
///   gutted to two "your app is outdated" stubs. Reading THAT file is the bug
///   this parser exists to fix, so it is pinned here as the fallback case.
const _base = 'https://raw.githubusercontent.com/keiyoushi/extensions/repo';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

void main() {
  group('MihonRepo.parseIndex — Mihon index.json', () {
    late List<AniyomiRepoEntry> entries;

    setUpAll(() {
      entries = MihonRepo.parseIndex(
        _fixture('keiyoushi_index.json'),
        repoBaseUrl: _base,
      );
    });

    test('reads every extension in the real keiyoushi index', () {
      expect(entries, hasLength(1369));
    });

    test('maps a single-source NSFW entry field by field', () {
      final e = entries.firstWhere(
        (e) => e.pkg == 'eu.kanade.tachiyomi.extension.all.ahottie',
      );
      expect(e.name, 'AHottie');
      expect(e.version, '1.6.4');
      // versionCode is the STRING "4" in this schema. A `as num` cast would
      // throw and a `(m['versionCode'] as num?)?.toInt() ?? 0` would silently
      // yield 0 — either way this line fails.
      expect(e.code, 4);
      expect(e.nsfw, isTrue);
      // The filename is kept (it names the file on disk), and the index's own
      // absolute apkUrl is honoured rather than rebuilt — see the Releases test
      // below for why rebuilding breaks the live repo.
      expect(e.apk, 'tachiyomi-all.ahottie-v1.6.4.apk');
      expect(
        e.apkUrl,
        'https://cdn.jsdelivr.net/gh/keiyoushi/extensions@repo/apk/'
        'tachiyomi-all.ahottie-v1.6.4.apk',
      );
      expect(e.lang, 'all');
      expect(e.sources, hasLength(1));
      final s = e.sources.single;
      // Source ids are decimal strings that need parsing, and the keys are
      // `language`/`homeUrl`, not `lang`/`baseUrl`.
      expect(s.id, 6289731484943315811);
      expect(s.name, 'AHottie');
      expect(s.lang, 'all');
      expect(s.baseUrl, 'https://ahottie.top');
    });

    test("maps a multi-source (multi-language) entry as 'all'", () {
      final e = entries.firstWhere(
        (e) => e.pkg == 'eu.kanade.tachiyomi.extension.all.comikey',
      );
      expect(e.name, 'Comikey');
      expect(e.code, 8);
      expect(e.sources, hasLength(5));
      expect(
        e.sources.map((s) => s.lang).toList(),
        ['en', 'es', 'id', 'pt-BR', 'pt-BR'],
      );
      // Sources span several languages → 'all', NOT the first source's lang.
      // Tagging it by the first source (e.g. MangaDex's alphabetically-first
      // "af") would let the language filter wrongly hide a multi-language
      // extension that actually contains the enabled language.
      expect(e.lang, 'all');
      expect(e.sources.first.id, 2769857481066602061);
    });

    test('only CONTENT_WARNING_NSFW counts as NSFW', () {
      final safe = entries.firstWhere(
        (e) => e.pkg == 'eu.kanade.tachiyomi.extension.all.comikey',
      );
      expect(safe.nsfw, isFalse);
      // CONTENT_WARNING_MIXED (406 of the 1,369) is not flagged either.
      final mixed = entries.firstWhere(
        (e) => e.pkg == 'eu.kanade.tachiyomi.extension.all.comicklive',
      );
      expect(mixed.nsfw, isFalse);
      expect(entries.where((e) => e.nsfw), hasLength(387));
    });

    test('every entry is installable — real pkg, apk filename and code', () {
      expect(entries.every((e) => e.pkg.isNotEmpty), isTrue);
      expect(entries.every((e) => e.apk.endsWith('.apk')), isTrue);
      expect(entries.every((e) => !e.apk.contains('/')), isTrue);
      expect(entries.every((e) => e.apkUrl.startsWith('http')), isTrue);
      expect(entries.every((e) => e.apkUrl.endsWith(e.apk)), isTrue);
      // A String→int regression on versionCode would collapse these to 0.
      expect(entries.where((e) => e.code > 0), hasLength(1369));
    });

    test('versionCode is read from a String, not only from a number', () {
      final entries = MihonRepo.parseIndex(
        '{"extensionList":{"extensions":[{'
        '"name":"S","packageName":"p.s","versionCode":"77","versionName":"1.7.7",'
        '"resources":{"apkUrl":"https://cdn/apk/s-v1.7.7.apk"},"sources":[]}]}}',
        repoBaseUrl: _base,
      );
      expect(entries.single.code, 77);
      expect(entries.single.lang, 'all'); // no sources → falls back to 'all'
    });

    // Keiyoushi moved its APKs off the repo tree to GitHub Releases (some time
    // after the 2026-08-05 fixture above, which still points at jsDelivr). The
    // download tag is per-build, so `<base>/apk/<file>` cannot be derived from
    // the repo URL — rebuilding it 404s on every one of the ~1400 extensions
    // and nothing installs. The index's own URL has to be used verbatim.
    test('a GitHub-Releases apkUrl is used as-is, not rebuilt from the base', () {
      const released =
          'https://github.com/keiyoushi/extensions/releases/download/'
          '88e1412-0/tachiyomi-all.ahottie-v1.6.4.apk';
      final entries = MihonRepo.parseIndex(
        '{"extensionList":{"extensions":[{'
        '"name":"AHottie","packageName":"p.a","versionCode":"4",'
        '"versionName":"1.6.4","resources":{"apkUrl":"$released"},'
        '"sources":[]}]}}',
        repoBaseUrl: _base,
      );
      expect(entries.single.apkUrl, released);
      expect(entries.single.apkUrl, isNot(startsWith('$_base/apk/')));
      // The bare filename is still what lands on disk.
      expect(entries.single.apk, 'tachiyomi-all.ahottie-v1.6.4.apk');
    });

    // index.pb is the PRIMARY format — it's tried before index.json and is
    // ~13x smaller, so it's the path a real install actually takes. It decodes
    // through the same entry mapping, but that's exactly why this is asserted
    // over real protobuf bytes rather than JSON: a regression that reintroduced
    // URL-rebuilding inside the pb path would leave a JSON-only test green
    // while every install still 404s.
    test('index.pb (the primary format) honours an absolute apkUrl', () {
      const released =
          'https://github.com/keiyoushi/extensions/releases/download/'
          'abc1234-0/tachiyomi-en-example-v1.2.3.apk';

      // proto3 wire encoders — see test/core/mihon/mihon_pb_index_test.dart.
      List<int> varint(int v) {
        final out = <int>[];
        var n = v;
        while (true) {
          final b = n & 0x7f;
          n >>= 7;
          if (n == 0) {
            out.add(b);
            break;
          }
          out.add(b | 0x80);
        }
        return out;
      }

      List<int> tag(int f, int w) => varint((f << 3) | w);
      List<int> varintField(int f, int v) => [...tag(f, 0), ...varint(v)];
      List<int> lenField(int f, List<int> p) =>
          [...tag(f, 2), ...varint(p.length), ...p];
      List<int> strField(int f, String s) => lenField(f, utf8.encode(s));

      final source = <int>[
        ...varintField(1, 12),
        ...strField(2, 'Example'),
        ...strField(3, 'en'),
        ...strField(4, 'https://e.test'),
      ];
      final ext = <int>[
        ...strField(1, 'Example'),
        ...strField(2, 'p.e'),
        ...lenField(3, strField(1, released)), // Resources { apkUrl=1 }
        ...varintField(5, 3),
        ...strField(6, '1.2.3'),
        ...lenField(8, source),
      ];
      final store = <int>[
        ...strField(1, 'TestRepo'),
        ...lenField(101, lenField(1, ext)),
      ];

      final entries = MihonRepo.parsePbIndex(
        gzip.encode(store),
        repoBaseUrl: _base,
      );

      expect(entries.single.apkUrl, released);
      expect(entries.single.apkUrl, isNot(startsWith('$_base/apk/')));
      expect(entries.single.apk, 'tachiyomi-en-example-v1.2.3.apk');
    });
  });

  group('MihonRepo.parseIndex — legacy index.min.json fallback', () {
    test('parses the legacy array shape via the anime parser', () {
      final entries = MihonRepo.parseIndex(
        _fixture('keiyoushi_index_min.json'),
        repoBaseUrl: _base,
      );
      // This is the shape the old code read — and this is all it ever got.
      expect(entries, hasLength(2));
      expect(entries.first.name, 'Outdated App');
      expect(entries.first.pkg, 'eu.kanade.tachiyomi.extension.all.keiyoushi');
      expect(entries.first.apk, 'tachiyomi-all.keiyoushi-v1.4.1.apk');
      expect(entries.first.lang, 'all');
      // `code` is a NUMBER in this schema, unlike the String above.
      expect(entries.first.code, 1);
      expect(entries.first.nsfw, isFalse);
      expect(entries.last.name, 'Update to Mihon 0.20.1+');
    });

    test('an empty legacy array is a valid (empty) repo, not an error', () {
      expect(MihonRepo.parseIndex('[]', repoBaseUrl: _base), isEmpty);
    });

    test('an empty extensions list is a valid (empty) repo', () {
      expect(
        MihonRepo.parseIndex(
          '{"extensionList":{"extensions":[]}}',
          repoBaseUrl: _base,
        ),
        isEmpty,
      );
    });
  });

  group('MihonRepo.parseIndex — failures are visible', () {
    test('invalid JSON throws instead of returning an empty list', () {
      expect(
        () => MihonRepo.parseIndex('not json at all', repoBaseUrl: _base),
        throwsA(isA<MihonRepoException>()),
      );
      // The contrast that made the original bug invisible: the anime parser
      // swallows the same input and reports "no extensions".
      expect(
        AniyomiRepo.parseIndex('not json at all', repoBaseUrl: _base),
        isEmpty,
      );
    });

    test('an unknown object shape throws with a message the UI can show', () {
      expect(
        () => MihonRepo.parseIndex(
          '{"name":"Some repo","extensions":[]}',
          repoBaseUrl: _base,
        ),
        throwsA(
          isA<MihonRepoException>().having(
            (e) => e.toString(),
            'message',
            contains('unrecognised repo index format'),
          ),
        ),
      );
    });

    test('malformed individual entries are skipped, not fatal', () {
      final entries = MihonRepo.parseIndex(
        '{"extensionList":{"extensions":['
        '"junk",'
        '{"name":"no pkg","resources":{"apkUrl":"https://cdn/apk/x.apk"}},'
        '{"name":"no apk","packageName":"p.b"},'
        '{"name":"Good","packageName":"p.g","versionCode":"2",'
        '"resources":{"apkUrl":"https://cdn/apk/g-v1.0.apk"},"sources":[]}'
        ']}}',
        repoBaseUrl: _base,
      );
      expect(entries.map((e) => e.name), ['Good']);
    });
  });

  group('MihonRepo.fetchIndex', () {
    setUp(() => GetIt.instance.reset());
    tearDown(() => GetIt.instance.reset());

    void registerDio(_RoutingAdapter adapter) {
      GetIt.instance.registerSingleton<Dio>(
        Dio()..httpClientAdapter = adapter,
      );
    }

    test('tries index.pb first, then index.json, never the legacy file',
        () async {
      final adapter = _RoutingAdapter({
        '$_base/index.json': _fixture('keiyoushi_index.json'),
        '$_base/index.min.json': _fixture('keiyoushi_index_min.json'),
      });
      registerDio(adapter);

      final entries = await MihonRepo.fetchIndex(_base);
      expect(entries, hasLength(1369));
      // index.pb is the smaller mirror of the same data, so it's asked for
      // first; this adapter doesn't serve it, so the run falls through to
      // index.json. The legacy file must never be reached once index.json
      // parses.
      expect(adapter.requested.first, '$_base/index.pb');
      expect(adapter.requested, contains('$_base/index.json'));
      expect(adapter.requested, isNot(contains('$_base/index.min.json')));
    });

    // ── The legacy fallback exists for exactly one case, and these two tests
    // pin its edges: absent index.json → use the old file; present but
    // unparseable index.json → say so, don't quietly serve the old file.

    test('falls back to the legacy index.min.json only when index.json 404s',
        () async {
      final adapter = _RoutingAdapter({
        '$_base/index.min.json': _fixture('keiyoushi_index_min.json'),
      });
      registerDio(adapter);

      final entries = await MihonRepo.fetchIndex(_base);
      expect(entries, hasLength(2));
      expect(entries.first.pkg, 'eu.kanade.tachiyomi.extension.all.keiyoushi');
      // Order matters: index.pb, then index.json (each direct then through
      // every mirror), and only then does the legacy file get a turn.
      expect(adapter.requested.first, '$_base/index.pb');
      expect(
        adapter.requested.indexOf('$_base/index.json'),
        lessThan(adapter.requested.indexOf('$_base/index.min.json')),
      );
    });

    test('a reachable but unparseable index.json raises instead of falling '
        'back to the legacy stub', () async {
      final adapter = _RoutingAdapter({
        // 200 OK, wrong shape — i.e. keiyoushi reshaped index.json again.
        '$_base/index.json': '{"totally":"different"}',
        '$_base/index.min.json': _fixture('keiyoushi_index_min.json'),
      });
      registerDio(adapter);

      await expectLater(
        MihonRepo.fetchIndex(_base),
        throwsA(
          isA<MihonRepoException>().having(
            (e) => e.toString(),
            'message',
            contains('unrecognised repo index format'),
          ),
        ),
      );
      // Returning the 2 deprecation stubs here would look exactly like the
      // bug this parser was written to fix, so the legacy file is never even
      // requested — and no mirror of index.json is retried either. (index.pb
      // is attempted first and 404s; only index.json itself is fetched.)
      expect(adapter.requested, isNot(contains('$_base/index.min.json')));
      expect(
        adapter.requested.where((u) => u.endsWith('/index.json')),
        hasLength(1),
      );
    });

    test('an index.json that is not JSON at all also raises', () async {
      registerDio(_RoutingAdapter({'$_base/index.json': '<html>blocked</html>'}));

      await expectLater(
        MihonRepo.fetchIndex(_base),
        throwsA(
          isA<MihonRepoException>().having(
            (e) => e.toString(),
            'message',
            contains("isn't valid JSON"),
          ),
        ),
      );
    });

    test('throws when no URL yields a usable index', () async {
      final adapter = _RoutingAdapter(const {});
      registerDio(adapter);

      await expectLater(
        MihonRepo.fetchIndex(_base),
        throwsA(isA<MihonRepoException>()),
      );
      // All three index files, each direct + 3 GitHub mirrors.
      expect(adapter.requested, hasLength(12));
    });

    test('a trailing /index.min.json in a saved URL is normalised away',
        () async {
      final adapter = _RoutingAdapter({
        '$_base/index.json': _fixture('keiyoushi_index.json'),
      });
      registerDio(adapter);

      final entries = await MihonRepo.fetchIndex('$_base/index.min.json');
      expect(entries, hasLength(1369));
      // Assert the normalisation directly: the saved filename is stripped and
      // the index is fetched from the DIRECTORY, never `…/index.min.json/…`.
      expect(adapter.requested, contains('$_base/index.json'));
      expect(
        adapter.requested.any((u) => u.contains('index.min.json/')),
        isFalse,
      );
    });
  });
}

/// Serves [bodies] by exact URL and 404s everything else, recording the order
/// URLs were tried in.
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.bodies);

  final Map<String, String> bodies;
  final List<String> requested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requested.add(url);
    final body = bodies[url];
    if (body == null) return ResponseBody.fromString('Not Found', 404);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
