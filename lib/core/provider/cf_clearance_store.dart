import 'package:hive/hive.dart';

/// Persists solved Cloudflare clearances (the cf_clearance cookie + the exact
/// User-Agent that solved it) per host, so a JS source that was cleared once
/// stays cleared across app restarts — instead of popping the "Verifying…"
/// WebView solver every fresh session. This mirrors what the CloudStream `.cs3`
/// path already gets for free via Android's persistent CookieManager; the JS
/// providers use the Dart Dio client, which has no such jar, so we keep our own.
///
/// A restored clearance is only an *optimistic* reuse: cf_clearance can expire
/// before [maxAge], so if a request with a restored cookie still gets challenged
/// the caller drops it ([forget]) and re-solves. So [maxAge] is just an upper
/// bound on how stale a cookie we'll bother trying — not a correctness boundary.
///
/// Tiny Hive box, same pattern as [SourceHealthStore] / [SearchSourcePrefs].
class CfClearanceStore {
  static const String boxName = 'cf_clearance';

  /// Don't reuse a persisted clearance older than this — re-solve instead. CF's
  /// cf_clearance commonly lasts hours; a still-valid one is reused silently, an
  /// expired one is dropped on its first challenge (one verify, then quiet).
  static const Duration maxAge = Duration(hours: 12);

  /// Opens the box. Call once during app bootstrap before the provider runtime
  /// issues any `browser: true` fetch.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box? get _box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// Non-expired clearances as host → (cookie, ua). Prunes stale entries as it
  /// reads. Best-effort: returns empty if the box isn't open.
  Map<String, ({String cookie, String? ua})> restore() {
    final box = _box;
    if (box == null) return const {};
    final out = <String, ({String cookie, String? ua})>{};
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final key in box.keys.toList()) {
      final raw = box.get(key);
      if (raw is! Map) {
        box.delete(key);
        continue;
      }
      final m = Map<String, dynamic>.from(raw);
      final cookie = m['cookie'] as String?;
      final ts = (m['ts'] as num?)?.toInt();
      if (cookie == null || cookie.isEmpty || ts == null) {
        box.delete(key);
        continue;
      }
      if (now - ts > maxAge.inMilliseconds) {
        box.delete(key); // too old to trust — re-solve next time it's needed
        continue;
      }
      out[key.toString()] = (cookie: cookie, ua: m['ua'] as String?);
    }
    return out;
  }

  /// Persist a freshly-solved clearance for [host].
  void remember(String host, String cookie, String? ua) {
    _box?.put(host, {
      'cookie': cookie,
      if (ua != null && ua.isNotEmpty) 'ua': ua,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Drop a clearance that turned out to be stale (got challenged on reuse).
  void forget(String host) => _box?.delete(host);
}
