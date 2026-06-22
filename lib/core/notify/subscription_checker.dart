import '../repository/source_repository.dart';
import 'notification_service.dart';
import 'subscription_store.dart';

/// Re-checks each subscribed show's source for new episodes (CloudStream-style)
/// and fires a notification when the episode count has grown. Uses the SAME
/// [SourceRepository.episodes] call the detail page uses, so it works for BOTH
/// JS and CS sources. Best-effort — a per-show failure is swallowed so one dead
/// source can't block the rest.
class SubscriptionChecker {
  SubscriptionChecker(this._repo, this._store);
  final SourceRepository _repo;
  final SubscriptionStore _store;

  bool _running = false;

  Future<void> checkAll() async {
    if (_running) return; // never overlap two sweeps
    _running = true;
    try {
      for (final sub in _store.all()) {
        // CS sources are handled by the native background worker (it can run
        // while the app is closed); skip them here to avoid double alerts.
        if (sub.sourceId.startsWith('cs:')) continue;
        try {
          final eps = await _repo
              .episodes(sub.url, sourceId: sub.sourceId)
              .timeout(const Duration(seconds: 25));
          final count = eps.length;
          if (count <= 0) continue;
          if (count > sub.lastCount) {
            // Don't alert on the very first sweep after a fresh subscribe
            // (lastCount seeded to 0) — only announce a genuine increase.
            if (sub.lastCount > 0) {
              await NotificationService.instance.showNewEpisode(
                id: sub.key.hashCode & 0x7fffffff,
                title: sub.title,
                episode: count,
                payload: '${sub.sourceId}|${sub.url}',
              );
            }
            await _store.setCount(sub.sourceId, sub.url, count);
          }
        } catch (_) {
          // dead/slow source — skip; retried next sweep.
        }
      }
    } finally {
      _running = false;
    }
  }
}
