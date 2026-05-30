/// Thrown when the JS runtime or a provider call fails.
class ProviderException implements Exception {
  ProviderException(this.message);
  final String message;
  @override
  String toString() => 'ProviderException: $message';
}

/// Thrown when the embedded QuickJS runtime rejects an eval or a call.
class JsRuntimeException implements Exception {
  JsRuntimeException(this.message);
  final String message;
  @override
  String toString() => 'JsRuntimeException: $message';
}

/// Thrown when a network download (provider/extractor JS, manifest) fails.
class NetworkException implements Exception {
  NetworkException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'NetworkException($statusCode): $message';
}
