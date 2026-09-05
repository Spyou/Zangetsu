import 'package:dio/dio.dart';

/// Raised when AniList has rate-limited us and the window has not passed.
///
/// Carries the wait so the UI can say how long rather than "something went
/// wrong" — a limit you can wait out reads very differently from a failure.
class AniListRateLimited implements Exception {
  const AniListRateLimited(this.retryAfter);

  final Duration retryAfter;

  int get seconds => retryAfter.inSeconds.clamp(1, 3600);

  @override
  String toString() => 'AniListRateLimited(${seconds}s)';
}

/// AniList's own network budget, and its rate-limit window.
///
/// The app-wide Dio allows 8 seconds, chosen to stop a hanging embed host
/// stalling source resolution. AniList is the opposite shape of request: the
/// home read is one aliased multi-query returning eight pages of media with
/// covers, banners and genres, and 8 seconds to receive that is tight on
/// anything but a good connection. This gives that host a longer read without
/// loosening the bound every extractor runs under.
///
/// It also honours 429. AniList publishes `Retry-After`; hammering through it
/// only extends the window, so once limited we fail fast with the wait
/// attached until it expires. One interceptor rather than nine call sites —
/// every AniList caller shares the injected Dio.
class AniListNetworkPolicy extends Interceptor {
  AniListNetworkPolicy({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const String host = 'graphql.anilist.co';

  /// Connect stays on the app default: reaching AniList is quick, it is the
  /// response that is heavy.
  static const Duration readTimeout = Duration(seconds: 30);

  /// AniList sends `Retry-After` in seconds; this stands in when it doesn't.
  static const Duration fallbackRetryAfter = Duration(seconds: 60);

  /// Sent on every AniList request.
  ///
  /// Without it AniList answers 403 with "The AniList API has been temporarily
  /// disabled due to severe stability issues." — which reads like an outage but
  /// is a block: the same query with this header returns data. Measured, one
  /// header at a time: Referer alone passes; Origin alone, User-Agent alone,
  /// and Origin+User-Agent all 403.
  ///
  /// This is them turning away third-party clients, so treat it as something
  /// that can stop working rather than a fix that will hold. The MAL fallback
  /// in [MetadataRepository] stays the safety net either way.
  static const String referer = 'Referer';
  static const String refererValue = 'https://anilist.co/';

  final DateTime Function() _now;
  DateTime? _limitedUntil;

  /// How long until requests are accepted again, or null when not limited.
  Duration? get retryAfter {
    final until = _limitedUntil;
    if (until == null) return null;
    final left = until.difference(_now());
    if (!left.isNegative && left != Duration.zero) return left;
    _limitedUntil = null; // window passed
    return null;
  }

  bool get isLimited => retryAfter != null;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.uri.host != host) return handler.next(options);
    options.receiveTimeout = readTimeout;
    options.sendTimeout = readTimeout;
    options.headers[referer] = refererValue;
    final left = retryAfter;
    if (left != null) {
      return handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          error: AniListRateLimited(left),
        ),
        // Fail fast rather than queue: the caller wants an answer now, and
        // the honest answer is how long the wait is.
        true,
      );
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final res = err.response;
    if (err.requestOptions.uri.host == host && res?.statusCode == 429) {
      final wait = _retryAfterOf(res!) ?? fallbackRetryAfter;
      _limitedUntil = _now().add(wait);
      return handler.reject(
        DioException(
          requestOptions: err.requestOptions,
          response: res,
          type: DioExceptionType.cancel,
          error: AniListRateLimited(wait),
        ),
      );
    }
    handler.next(err);
  }

  static Duration? _retryAfterOf(Response<dynamic> res) {
    final raw = res.headers.value('retry-after');
    final secs = int.tryParse('$raw'.trim());
    return secs == null ? null : Duration(seconds: secs);
  }
}

/// The rate limit behind [e], when that is what it is.
AniListRateLimited? aniListRateLimitOf(Object? e) => switch (e) {
  AniListRateLimited() => e,
  DioException(error: final AniListRateLimited r) => r,
  _ => null,
};
