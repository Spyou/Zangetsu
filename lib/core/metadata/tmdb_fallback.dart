import 'package:dio/dio.dart';

import 'tmdb.dart';

/// Retries a TMDB call that never got an answer on [Tmdb.fallbackHost].
///
/// A network that blocks TMDB fails with a timeout or a dead connection and
/// never a real status, which is exactly what separates "your ISP blocks this"
/// from "no such id". Indian ISPs hijack the DNS for [Tmdb.host]; TMDB's other
/// host is not on the same blocklists and serves the same API.
///
/// Deliberately narrow:
///  * a genuine 404 carries a response, so it passes straight through;
///  * a request to any other host is ignored;
///  * the retry goes to a different host, so it cannot match again and loop;
///  * if the retry fails too, the ORIGINAL error is reported — a caller should
///    never see "api.tmdb.org" in a message when that is not what it asked for.
class TmdbFallbackInterceptor extends Interceptor {
  TmdbFallbackInterceptor(this._dio);

  final Dio _dio;

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final o = err.requestOptions;
    if (err.response == null && o.uri.host == Tmdb.host) {
      try {
        handler.resolve(
          await _dio.fetch<dynamic>(
            o.copyWith(path: o.path.replaceFirst(Tmdb.host, Tmdb.fallbackHost)),
          ),
        );
        return;
      } catch (_) {
        // Blocked there too, or simply offline — fall through.
      }
    }
    handler.next(err);
  }
}
