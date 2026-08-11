/// Raised when a Mihon manga source is blocked by a Cloudflare challenge the
/// headless solver couldn't pass (an interactive Turnstile). [url] is the page
/// to open in the visible WebView solve ([MihonExtensionService.solveCloudflare]).
///
/// The native bridge reports this as a `PlatformException(code: 'CLOUDFLARE',
/// message: url)`; [MihonProvider] re-throws it as this typed exception on the
/// browse/home path so the UI can offer a "Solve Cloudflare" action instead of a
/// generic "source unavailable".
class CloudflareRequiredException implements Exception {
  const CloudflareRequiredException(this.url);

  /// The page URL to load in the solve WebView.
  final String url;

  @override
  String toString() => 'CloudflareRequiredException($url)';
}
