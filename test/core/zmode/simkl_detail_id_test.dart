// Simkl's records are keyed by its own id and we hold a TMDB one, so opening
// a detail needs a translation first. It used to be /search/id, which returns
// a whole record we throw away; Simkl asked us onto /redirect, which answers
// 301 with the id in the Location header and no body at all.

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/zmode/simkl_catalogue.dart';
import 'package:watch_app/core/zmode/zmode_ids.dart';

/// Answers `/redirect` the way Simkl does — a 301 whose Location carries the
/// id — and serves the record for everything else.
class _Adapter implements HttpClientAdapter {
  _Adapter({required this.location, this.record = const {'title': 'A Title'}});

  /// The Location header for /redirect. `null` = the bare `//simkl.com` Simkl
  /// sends when it has no record.
  final String? location;
  final Map<String, dynamic> record;
  final asked = <Uri>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, _, __) async {
    asked.add(o.uri);
    if (o.uri.path == '/redirect') {
      return ResponseBody.fromString(
        '',
        301,
        headers: {
          'location': [location ?? '//simkl.com?client_id=x'],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(record),
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
  setUp(SimklCatalogue.resetIdCache);

  const movie = ZCanonical(ZKind.movie, 'tmdb:550');
  const series = ZCanonical(ZKind.tv, 'tmdb:1399');

  test('reads the id out of the Location header', () async {
    final adapter = _Adapter(
      location: '//simkl.com/movies/53894/fight-club?client_id=x',
      record: const {'title': 'Fight Club'},
    );
    final cat = SimklCatalogue(Dio()..httpClientAdapter = adapter);

    final d = await cat.detail(movie);

    expect(d.title, 'Fight Club');
    expect(
      adapter.asked.last.path,
      '/movies/53894',
      reason: 'the record fetch must use the id the redirect gave',
    );
  });

  test('does not follow the 301', () async {
    // Following it would fetch a Simkl *web page* — HTML, not a record — and
    // spend a request doing it. The header is the whole answer.
    late bool followed;
    final dio = Dio()
      ..httpClientAdapter = _Adapter(
        location: '//simkl.com/tv/17465/game-of-thrones',
      )
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) {
            if (o.uri.path == '/redirect') followed = o.followRedirects;
            h.next(o);
          },
        ),
      );

    await SimklCatalogue(dio).detail(series);

    expect(followed, isFalse);
  });

  test('a series says so, or it gets searched as a film', () async {
    // Without `type` a series id resolves against MOVIES and comes back with
    // no id at all — every show failed to open while films were fine.
    final adapter = _Adapter(location: '//simkl.com/tv/17465/game-of-thrones');
    await SimklCatalogue(Dio()..httpClientAdapter = adapter).detail(series);

    expect(adapter.asked.first.queryParameters['type'], 'tv');
  });

  test('a movie asks for movies', () async {
    final adapter = _Adapter(location: '//simkl.com/movies/53894/fight-club');
    await SimklCatalogue(Dio()..httpClientAdapter = adapter).detail(movie);

    expect(adapter.asked.first.queryParameters['type'], 'movie');
  });

  test('a genuinely unknown title still fails loudly', () async {
    // Simkl answers a bare `//simkl.com` with no id. Falling back to TMDB is
    // right HERE — the bug this guards was doing it for everything.
    final cat = SimklCatalogue(
      Dio()..httpClientAdapter = _Adapter(location: null),
    );

    expect(
      () => cat.detail(const ZCanonical(ZKind.movie, 'tmdb:99999999')),
      throwsA(isA<StateError>()),
    );
  });

  test('resolving twice only asks once', () async {
    final adapter = _Adapter(location: '//simkl.com/movies/53894/fight-club');
    final cat = SimklCatalogue(Dio()..httpClientAdapter = adapter);

    await cat.detail(movie);
    await cat.detail(movie);

    expect(
      adapter.asked.where((u) => u.path == '/redirect'),
      hasLength(1),
      reason: 'the id was already known the second time',
    );
  });
}
