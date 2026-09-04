import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/anilist/anilist_network_policy.dart';
import 'package:watch_app/core/zmode/anilist_catalogue.dart';

// The client used to swallow every failure and return null, which the caller
// could not tell apart from a catalogue that simply had nothing. Home then
// could not tell an offline phone from a provider outage, and told people with
// no network to switch metadata provider.

Dio _dioThatFails(DioException e) {
  final dio = Dio();
  dio.httpClientAdapter = _FailingAdapter(e);
  return dio;
}

class _FailingAdapter implements HttpClientAdapter {
  _FailingAdapter(this.error);
  final DioException error;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? s, Future<void>? f) async =>
      throw error;
}

Dio _dioThatAnswers(int status, dynamic body) {
  final dio = Dio();
  dio.httpClientAdapter = _AnsweringAdapter(status, body);
  return dio;
}

class _AnsweringAdapter implements HttpClientAdapter {
  _AnsweringAdapter(this.status, this.body);
  final int status;
  final dynamic body;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? s, Future<void>? f) async =>
      ResponseBody.fromString(
        body is String ? body : '$body',
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
}

RequestOptions get _opts => RequestOptions(path: 'https://graphql.anilist.co');

void main() {
  test('a transport failure propagates instead of reading as empty', () async {
    final dio = _dioThatFails(
      DioException(
        requestOptions: _opts,
        type: DioExceptionType.connectionError,
        error: 'no route',
      ),
    );
    await expectLater(
      AniListCatalogue.dioGql(dio)('query{ x }', const {}),
      throwsA(isA<DioException>()),
    );
  });

  test('a rate limit propagates so the wait can be shown', () async {
    final dio = _dioThatFails(
      DioException(
        requestOptions: _opts,
        response: Response<dynamic>(requestOptions: _opts, statusCode: 429),
        type: DioExceptionType.cancel,
        error: const AniListRateLimited(Duration(seconds: 30)),
      ),
    );
    await expectLater(
      AniListCatalogue.dioGql(dio)('query{ x }', const {}),
      throwsA(
        isA<DioException>().having(
          (e) => aniListRateLimitOf(e)?.seconds,
          'rate limit',
          30,
        ),
      ),
    );
  });

  test('a server that answered still reads as nothing, not a throw', () async {
    // A GraphQL error envelope is the server replying; every caller already
    // treats that as "no data" and must keep doing so.
    final dio = _dioThatAnswers(200, '{"errors":[{"message":"nope"}]}');
    expect(await AniListCatalogue.dioGql(dio)('query{ x }', const {}), isNull);
  });

  test('a good response still parses', () async {
    final dio = _dioThatAnswers(200, '{"data":{"r0":{"media":[]}}}');
    final out = await AniListCatalogue.dioGql(dio)('query{ x }', const {});
    expect(out, isNotNull);
    expect(out!['r0'], isA<Map>());
  });
}
