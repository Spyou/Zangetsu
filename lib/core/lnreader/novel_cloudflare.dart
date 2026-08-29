/// Remembers that a novel source's last fetch hit a Cloudflare challenge.
///
/// Why a latch rather than an exception: an LNReader plugin is JavaScript and
/// catches its own fetch failures, so a rejected request surfaces as an empty
/// result list — nothing propagates out of the runtime for the UI to catch.
///
/// The prompt this drives is not cosmetic. Solving mints a `cf_clearance` under
/// the device's real User-Agent, which NovelHttp's cookie jar then sends; a
/// fresh install has no such cookie and stays blocked without it (verified —
/// with the right UA but no cookie, the source still fails).
///
/// In-memory on purpose: a clearance is short-lived, and a stale "needs
/// solving" flag would nag about a site that has since started working.
class NovelCloudflare {
  NovelCloudflare._();

  static String? _pendingUrl;

  /// The page to open in the solver, or null when nothing is waiting.
  static String? get pendingUrl => _pendingUrl;

  static void needsSolve(String url) => _pendingUrl = url;

  static void clear() => _pendingUrl = null;
}
