import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// The reliability state of a single source, derived from search/probe outcomes.
///
///  - [ok]    — responded without error/timeout (even 0 results counts).
///  - [slow]  — responded, but over the slow threshold.
///  - [dead]  — errored or timed out. RECOVERABLE: a dead mark expires after
///              [SourceHealthStore.recheckWindow] and the source is retried.
enum SourceHealth { ok, slow, dead }

/// The outcome of one search/probe attempt against a source. This is what the
/// caller knows; the store turns it into a [SourceHealth] + a short reason.
///
/// CRITICAL: [empty] (0 results WITHOUT an error/timeout) is ALIVE, not dead —
/// many sources legitimately return nothing for niche queries. Only [timeout],
/// [blocked] and [error] count against a source's health.
enum SourceOutcome {
  ok, // responded with results
  empty, // responded with 0 results, no error → still alive
  slow, // responded (with or without results) but over the slow threshold
  timeout, // the probe/search capped out
  blocked, // a Cloudflare / WAF block
  error, // any other thrown failure
}

/// One persisted health record for a source.
class SourceHealthRecord {
  const SourceHealthRecord({
    required this.status,
    required this.reason,
    required this.checkedAtMs,
    this.responseMs,
  });

  final SourceHealth status;

  /// A short human reason: "ok" / "slow" / "timeout" / "blocked" / "error".
  final String reason;

  /// Epoch-ms of the last outcome recorded for this source.
  final int checkedAtMs;

  /// Last measured response time (ms) when the source responded; null otherwise.
  final int? responseMs;

  DateTime get checkedAt => DateTime.fromMillisecondsSinceEpoch(checkedAtMs);

  Map<String, dynamic> toMap() => {
    'status': status.name,
    'reason': reason,
    'checkedAtMs': checkedAtMs,
    if (responseMs != null) 'responseMs': responseMs,
  };

  static SourceHealthRecord? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final status = SourceHealth.values.firstWhere(
      (s) => s.name == m['status'],
      orElse: () => SourceHealth.ok,
    );
    final checkedAtMs = (m['checkedAtMs'] as num?)?.toInt();
    if (checkedAtMs == null) return null;
    return SourceHealthRecord(
      status: status,
      reason: (m['reason'] ?? status.name).toString(),
      checkedAtMs: checkedAtMs,
      responseMs: (m['responseMs'] as num?)?.toInt(),
    );
  }
}

/// Tracks per-source reliability so search can order healthy sources first and
/// temporarily skip dead ones (recoverably). Backed by a tiny Hive box, same
/// pattern as [SearchSourcePrefs] / [SearchPrefs].
///
/// Design rules (mirrors the CF negative-cache in [ProviderManager]):
///  - A "dead" mark is NEVER a permanent blacklist. It expires after
///    [recheckWindow] and the source is retried on the next search/probe.
///  - Empty-without-error is recorded as [SourceHealth.ok], never a strike.
///  - Best-effort: every accessor is null-safe and an unknown source is treated
///    as healthy, so this can never block or break search.
///
/// A [ChangeNotifier] so the health screen rebuilds as records update.
class SourceHealthStore extends ChangeNotifier {
  static const String boxName = 'source_health';

  /// How long a "dead" source is skipped before it's retried. Mirrors the CF
  /// 30-min negative-cache window so a source we can't reach isn't hammered yet
  /// is never permanently shut out.
  static const Duration recheckWindow = Duration(minutes: 30);

  /// Responses slower than this are flagged "slow" (responded, but sluggish).
  static const Duration slowThreshold = Duration(seconds: 4);

  /// Opens the box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box? get _box => Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// The current record for [id], or null if the source was never checked.
  SourceHealthRecord? recordOf(String id) =>
      SourceHealthRecord.fromMap(_box?.get(id));

  /// The last-known status for [id]. Unknown → [SourceHealth.ok] (treat as
  /// healthy when unsure). A stale "dead" mark (past [recheckWindow]) also reads
  /// as ok, so the source surfaces as retryable rather than dead.
  SourceHealth statusOf(String id) {
    final r = recordOf(id);
    if (r == null) return SourceHealth.ok;
    if (r.status == SourceHealth.dead && !_isFresh(r)) return SourceHealth.ok;
    return r.status;
  }

  /// True only while a FRESH "dead" mark is within [recheckWindow]. Search uses
  /// this to skip a source without querying it — but only until the window
  /// lapses, after which the source is retried (never permanently blacklisted).
  bool isSkippable(String id) {
    final r = recordOf(id);
    return r != null && r.status == SourceHealth.dead && _isFresh(r);
  }

  bool _isFresh(SourceHealthRecord r) =>
      DateTime.now().difference(r.checkedAt) < recheckWindow;

  /// Records the outcome of one search/probe attempt against [id]. [responseMs]
  /// is the measured round-trip when known (drives the "slow" classification and
  /// the response-time shown on the health screen).
  ///
  /// Mapping: ok/empty → ok (empty is NOT a strike); slow → slow; timeout →
  /// dead("timeout"); blocked → dead("blocked"); error → dead("error").
  Future<void> record(String id, SourceOutcome outcome, {int? responseMs}) async {
    final box = _box;
    if (box == null) return;
    // Only a hard error is "dead" (and thus skippable in search). slow / timeout
    // (just slow — e.g. Stremio's addon search) / Cloudflare-blocked / empty all
    // mean the source is ALIVE, so they read as ok.
    final (status, reason) = switch (outcome) {
      SourceOutcome.error => (SourceHealth.dead, 'error'),
      _ => (SourceHealth.ok, 'ok'),
    };
    await box.put(
      id,
      SourceHealthRecord(
        status: status,
        reason: reason,
        checkedAtMs: DateTime.now().millisecondsSinceEpoch,
        responseMs: responseMs,
      ).toMap(),
    );
    notifyListeners();
  }

  /// Drops the record for [id] so it's treated as healthy/unknown again.
  Future<void> clear(String id) async {
    await _box?.delete(id);
    notifyListeners();
  }
}
