import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/anilist/anilist_network_policy.dart';

// AniList shares the app-wide Dio, whose 8s bound exists to stop a hanging
// embed host stalling source resolution. The home read is the opposite shape
// of request — one multi-query returning eight pages of media — so it gets its
// own read budget, and honours 429 instead of hammering through it.

/// The handler completes a Future with the rejection; nothing awaits it here,
/// and an unconsumed error future fails the test on its own.
ErrorInterceptorHandler _errHandler() {
  final h = ErrorInterceptorHandler();
  h.future.ignore();
  return h;
}

RequestOptions _req({String host = AniListNetworkPolicy.host}) =>
    RequestOptions(path: 'https://$host/', baseUrl: 'https://$host');

Response<dynamic> _res429({String? retryAfter}) => Response<dynamic>(
  requestOptions: _req(),
  statusCode: 429,
  headers: Headers.fromMap({
    if (retryAfter != null) 'retry-after': [retryAfter],
  }),
);

void main() {
  test('AniList requests get the long read; other hosts keep the default', () {
    final policy = AniListNetworkPolicy();

    final ani = _req();
    policy.onRequest(ani, RequestInterceptorHandler());
    expect(ani.receiveTimeout, AniListNetworkPolicy.readTimeout);

    // An extractor must not inherit AniList's patience.
    final other = _req(host: 'some-embed-host.example');
    final before = other.receiveTimeout;
    policy.onRequest(other, RequestInterceptorHandler());
    expect(other.receiveTimeout, before);
  });

  // Without this header AniList answers 403 "temporarily disabled" — which
  // reads as an outage but is a block on third-party clients. Measured one
  // header at a time: Referer alone passes, Origin alone and User-Agent alone
  // do not. Losing it silently drops every AniList call onto the MAL fallback,
  // so it is worth a test rather than a comment.
  test('AniList requests carry the Referer that keeps them out of the 403', () {
    final policy = AniListNetworkPolicy();
    final ani = _req();
    policy.onRequest(ani, RequestInterceptorHandler());
    expect(ani.headers[AniListNetworkPolicy.referer], 'https://anilist.co/');
  });

  test('other hosts are not given an AniList Referer', () {
    final policy = AniListNetworkPolicy();
    final other = _req(host: 'some-embed-host.example');
    policy.onRequest(other, RequestInterceptorHandler());
    expect(other.headers[AniListNetworkPolicy.referer], isNull);
  });

  test('a 429 records the window from Retry-After', () {
    var now = DateTime(2026, 1, 1, 12);
    final policy = AniListNetworkPolicy(now: () => now);

    policy.onError(
      DioException(requestOptions: _req(), response: _res429(retryAfter: '30')),
      _errHandler(),
    );

    expect(policy.isLimited, isTrue);
    expect(policy.retryAfter!.inSeconds, 30);

    // It expires on its own rather than needing a successful call to clear.
    now = now.add(const Duration(seconds: 31));
    expect(policy.isLimited, isFalse);
    expect(policy.retryAfter, isNull);
  });

  test('a 429 with no Retry-After still backs off', () {
    final policy = AniListNetworkPolicy(now: () => DateTime(2026));
    policy.onError(
      DioException(requestOptions: _req(), response: _res429()),
      _errHandler(),
    );
    expect(
      policy.retryAfter!.inSeconds,
      AniListNetworkPolicy.fallbackRetryAfter.inSeconds,
    );
  });

  test('a 429 from another host is not AniList being limited', () {
    final policy = AniListNetworkPolicy(now: () => DateTime(2026));
    policy.onError(
      DioException(
        requestOptions: _req(host: 'other.example'),
        response: Response<dynamic>(
          requestOptions: _req(host: 'other.example'),
          statusCode: 429,
        ),
      ),
      _errHandler(),
    );
    expect(policy.isLimited, isFalse);
  });

  test('the rate limit is recognisable through a DioException', () {
    const limit = AniListRateLimited(Duration(seconds: 12));
    expect(aniListRateLimitOf(limit), limit);
    expect(
      aniListRateLimitOf(
        DioException(requestOptions: _req(), error: limit),
      )?.seconds,
      12,
    );
    expect(aniListRateLimitOf(Exception('nope')), isNull);
  });

  test('seconds never reads as zero or negative', () {
    // "try again in 0s" is worse than no number at all.
    expect(const AniListRateLimited(Duration.zero).seconds, 1);
    expect(const AniListRateLimited(Duration(seconds: -5)).seconds, 1);
  });
}
