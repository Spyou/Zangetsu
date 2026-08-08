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
      // resources.apkUrl points at jsDelivr; only the filename survives, so
      // the download resolves against the repo the user actually added.
      expect(e.apk, 'tachiyomi-all.ahottie-v1.6.4.apk');
      expect(e.apkUrl, '$_base/apk/tachiyomi-all.ahottie-v1.6.4.apk');
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

    test('maps a multi-source entry, taking lang from its first source', () {
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
      // Not 'all': the package is `.all.` but its first source is English.
      expect(e.lang, 'en');
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
      expect(entries.every((e) => e.apkUrl.startsWith('$_base/apk/')), isTrue);
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

    test('prefers index.json', () async {
      final adapter = _RoutingAdapter({
        '$_base/index.json': _fixture('keiyoushi_index.json'),
        '$_base/index.min.json': _fixture('keiyoushi_index_min.json'),
      });
      registerDio(adapter);

      final entries = await MihonRepo.fetchIndex(_base);
      expect(entries, hasLength(1369));
      expect(adapter.requested, ['$_base/index.json']);
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
      // index.json is tried first, direct then through every mirror, before
      // the legacy file gets a turn.
      expect(adapter.requested.first, '$_base/index.json');
      expect(adapter.requested, contains('$_base/index.min.json'));
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
      // requested — and no mirror of index.json is retried either.
      expect(adapter.requested, ['$_base/index.json']);
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
      // Both files, each direct + 3 GitHub mirrors.
      expect(adapter.requested, hasLength(8));
    });

    test('a trailing /index.min.json in a saved URL is normalised away',
        () async {
      final adapter = _RoutingAdapter({
        '$_base/index.json': _fixture('keiyoushi_index.json'),
      });
      registerDio(adapter);

      final entries = await MihonRepo.fetchIndex('$_base/index.min.json');
      expect(entries, hasLength(1369));
      expect(entries.first.apkUrl, startsWith('$_base/apk/'));
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
