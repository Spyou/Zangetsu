// Simkl spells its own id two ways depending on the endpoint: /search/id
// answers with `simkl`, while /search/* elsewhere uses `simkl_id`. Reading
// only the latter made every detail lookup null, so the provider threw for
// every title and quietly fell back to TMDB.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/simkl_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final Object? Function(String path) respond;
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, _, __) async {
    paths.add(o.uri.path);
    return ResponseBody.fromString(
      jsonEncode(respond(o.uri.path)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const c = ZCanonical(ZKind.movie, 'tmdb:969681');

  test('resolves a title whose lookup uses the `simkl` key', () async {
    final adapter = _Adapter((path) {
      if (path.contains('/search/id')) {
        // Exactly what the live endpoint returns.
        return [
          {
            'type': 'movie',
            'title': 'Spider-Man: Brand New Day',
            'ids': {'simkl': 1902343, 'slug': 'spider-man-brand-new-day'},
          },
        ];
      }
      return {'title': 'Spider-Man: Brand New Day', 'ids': {'simkl': 1902343}};
    });
    final cat = SimklCatalogue(Dio()..httpClientAdapter = adapter);

    final d = await cat.detail(c);

    expect(d.title, 'Spider-Man: Brand New Day');
    expect(adapter.paths.any((p) => p.contains('1902343')), isTrue,
        reason: 'the second hop must use the id from the first');
  });

  test('still resolves the other spelling', () async {
    final cat = SimklCatalogue(
      Dio()
        ..httpClientAdapter = _Adapter((path) {
          if (path.contains('/search/id')) {
            return [
              {'ids': {'simkl_id': 55}, 'title': 'Other'},
            ];
          }
          return {'title': 'Other'};
        }),
    );

    final d = await cat.detail(c);
    expect(d.title, 'Other');
  });

  test('a genuinely unknown title still fails loudly', () async {
    final cat = SimklCatalogue(
      Dio()..httpClientAdapter = _Adapter((_) => const []),
    );

    // Falling back to TMDB is right HERE — the bug was doing it for
    // everything.
    expect(() => cat.detail(c), throwsA(isA<StateError>()));
  });

  test('a series lookup says which catalogue to search', () async {
    // /search/id searches MOVIES unless told otherwise, so without this every
    // show came back empty while films worked — "some titles fail to load".
    late Uri asked;
    final cat = SimklCatalogue(
      Dio()
        ..httpClientAdapter = _Capture((uri) {
          // Only the lookup: hop 2 carries no type and would overwrite this.
          if (uri.path.contains('/search/id')) {
            asked = uri;
            return [
              {'ids': {'simkl': 1648964}, 'title': 'Silo'},
            ];
          }
          return {'title': 'Silo'};
        }),
    );

    await cat.detail(const ZCanonical(ZKind.tv, 'tmdb:125988'));

    expect(asked.queryParameters['type'], 'show');
  });

  test('a movie lookup asks for movies', () async {
    late Uri asked;
    final cat = SimklCatalogue(
      Dio()
        ..httpClientAdapter = _Capture((uri) {
          if (uri.path.contains('/search/id')) {
            asked = uri;
            return [
              {'ids': {'simkl': 1}, 'title': 'A Film'},
            ];
          }
          return {'title': 'A Film'};
        }),
    );

    await cat.detail(const ZCanonical(ZKind.movie, 'tmdb:550'));

    expect(asked.queryParameters['type'], 'movie');
  });
}

/// Captures the URI so a test can assert on the query, not just the path.
class _Capture implements HttpClientAdapter {
  _Capture(this.respond);
  final Object? Function(Uri uri) respond;

  @override
  Future<ResponseBody> fetch(RequestOptions o, _, __) async =>
      ResponseBody.fromString(
        jsonEncode(respond(o.uri)),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
