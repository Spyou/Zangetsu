import 'package:dio/dio.dart';

enum DebridFailure { notCached, auth, timeout, unsupported, error }

class DebridResolved {
  const DebridResolved({
    required this.url,
    this.filename,
    this.bytes,
  });

  final String url;
  final String? filename;
  final int? bytes;
}

class DebridException implements Exception {
  const DebridException(this.kind, this.message, {this.serviceName});

  final DebridFailure kind;
  final String message;
  final String? serviceName;

  factory DebridException.fromDio(DioException e, String service) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 403) {
      return DebridException(
        DebridFailure.auth,
        '$service rejected the API token. Reconnect in Settings › Debrid.',
        serviceName: service,
      );
    }
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return DebridException(
        DebridFailure.timeout,
        '$service timed out.',
        serviceName: service,
      );
    }
    final body = e.response?.data;
    String? apiErr;
    if (body is Map) {
      apiErr = (body['error'] ?? body['detail'] ?? body['message'])?.toString();
    }
    return DebridException(
      DebridFailure.error,
      apiErr == null || apiErr.isEmpty
          ? "Couldn't reach $service."
          : '$service: $apiErr',
      serviceName: service,
    );
  }

  @override
  String toString() => message;
}

/// Outcome of a [DebridResolver] attempt — Off/no-token is [DebridSkipped],
/// not an exception.
sealed class DebridAttempt {
  const DebridAttempt();
}

class DebridSkipped extends DebridAttempt {
  const DebridSkipped();
}

class DebridOk extends DebridAttempt {
  const DebridOk(this.resolved);
  final DebridResolved resolved;
}

class DebridFailed extends DebridAttempt {
  const DebridFailed(this.error);
  final DebridException error;
}
