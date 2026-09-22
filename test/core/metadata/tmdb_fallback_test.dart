import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/metadata/tmdb.dart';
import 'package:watch_app/core/metadata/tmdb_fallback.dart';

/// Indian ISPs hijack the DNS for [Tmdb.host]: it resolves to a local IP that
/// swallows the connection, so every TMDB call times out and the app reported
/// "TMDB returned nothing" for titles that plainly exist. Measured on Jio,
/// [Tmdb.fallbackHost] answers the same request in half a second.
void main() {
  late List<String> hosts;

  Dio dioThatBlocks(Set<String> blocked, {int status = 200}) {
    hosts = [];
    final dio = Dio()
      ..httpClientAdapter = _Adapter((o) async {
        hosts.add(o.uri.host);
        if (blocked.contains(o.uri.host)) {
          throw DioException.connectionTimeout(
            timeout: const Duration(seconds: 12),
            requestOptions: o,
          );
        }
        return ResponseBody.fromString(
          jsonEncode({'id': 523366, 'title': 'Dragon Rider'}),
          status,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
    dio.interceptors.add(TmdbFallbackInterceptor(dio));
    return dio;
  }

  test('a blocked TMDB call is retried on the other host', () async {
    final dio = dioThatBlocks({Tmdb.host});

    final res = await dio.get<dynamic>('${Tmdb.base}/movie/523366');

    expect(res.statusCode, 200);
    expect((res.data as Map)['title'], 'Dragon Rider');
    expect(hosts, [Tmdb.host, Tmdb.fallbackHost]);
  });

  test('an unblocked call never touches the other host', () async {
    final dio = dioThatBlocks(const {});

    await dio.get<dynamic>('${Tmdb.base}/movie/523366');

    expect(hosts, [Tmdb.host], reason: 'the retry must cost nothing normally');
  });

  test('a real HTTP failure is not retried', () async {
    // A 404 carries a response, so it is TMDB answering, not a blocked
    // network — asking the other host would only waste a round trip and
    // return the same 404.
    final dio = dioThatBlocks(const {}, status: 404);

    await expectLater(
      dio.get<dynamic>('${Tmdb.base}/movie/1'),
      throwsA(isA<DioException>()),
    );
    expect(hosts, [Tmdb.host]);
  });

  test('blocked on both hosts reports the original failure', () async {
    final dio = dioThatBlocks({Tmdb.host, Tmdb.fallbackHost});

    await expectLater(
      dio.get<dynamic>('${Tmdb.base}/movie/523366'),
      throwsA(
        isA<DioException>().having(
          (e) => e.requestOptions.uri.host,
          'the host the caller asked for',
          Tmdb.host,
        ),
      ),
    );
    expect(hosts, [Tmdb.host, Tmdb.fallbackHost]);
  });

  test('a failure on another service is left alone', () async {
    final dio = dioThatBlocks({'graphql.anilist.co'});

    await expectLater(
      dio.get<dynamic>('https://graphql.anilist.co/'),
      throwsA(isA<DioException>()),
    );
    expect(hosts, ['graphql.anilist.co']);
  });
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this._handle);

  final Future<ResponseBody> Function(RequestOptions) _handle;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => _handle(options);

  @override
  void close({bool force = false}) {}
}
