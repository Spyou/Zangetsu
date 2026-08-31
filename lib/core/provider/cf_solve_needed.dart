/// Remembers which JS-provider hosts hit a Cloudflare challenge while a
/// solve was deliberately suppressed — see `_suppressCfSolve` in
/// `_JsHost._runCall`/`_onFetch` (provider_manager.dart), set for the
/// duration of a `search` call so a passive multi-source sweep never pops
/// the blocking WebView solver.
///
/// Z Mode matches a metadata title to a source BY searching it, so a
/// suppressed challenge makes that source return nothing and the matcher
/// silently drops it — nothing else records that the source would have
/// worked after a solve. Same shape as [NovelCloudflare]
/// (lib/core/lnreader/novel_cloudflare.dart): a provider swallows its own
/// failure (an empty result, not an exception), so the fact gets stashed
/// here for whoever renders the affected UI to pick up and act on.
///
/// In-memory only, on purpose: this is a transient signal, not a
/// preference. A stale "needs solving" flag would nag about a host that has
/// since started working, so it is never persisted to Hive.
class CfSolveNeeded {
  CfSolveNeeded._();

  // host -> (sourceId, challenge url). sourceId is best-effort — the JS
  // bootstrap tags every fetch with its provider's __src, but that's null
  // for a request made outside any loaded provider's namespace.
  static final Map<String, ({String? sourceId, String url})> _hosts = {};

  static void needsSolve(String host, String url, {String? sourceId}) {
    // ignore: avoid_print
    print('[cfneed] FLAGGED host=$host sourceId=$sourceId url=$url');
    _hosts[host] = (sourceId: sourceId, url: url);
  }

  /// Clears the flag for [host] — call once a solve for it succeeds.
  static void clear(String host) => _hosts.remove(host);

  static bool hostFlagged(String host) => _hosts.containsKey(host);

  static bool sourceFlagged(String sourceId) {
    final hit = _hosts.values.any((v) => v.sourceId == sourceId);
    // ignore: avoid_print
    print('[cfneed] check sourceId=$sourceId -> $hit '
        '(flagged: ${_hosts.values.map((v) => v.sourceId).toList()})');
    return hit;
  }

  /// The challenge url recorded for [sourceId], or null when it isn't flagged.
  static String? urlFor(String sourceId) {
    for (final v in _hosts.values) {
      if (v.sourceId == sourceId) return v.url;
    }
    return null;
  }

  /// The challenge url for the first of [sourceIds] that's flagged, or null.
  static String? urlForAny(Iterable<String> sourceIds) {
    for (final id in sourceIds) {
      final u = urlFor(id);
      if (u != null) return u;
    }
    return null;
  }
}
