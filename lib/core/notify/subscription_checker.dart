import '../logging/app_logger.dart';
import '../repository/catalogue_repository.dart';
import 'notification_service.dart';
import 'subscription_store.dart';

/// Re-checks each subscribed show's source for new episodes or chapters
/// (CloudStream-style) and fires a notification when the count has grown. Uses
/// the SAME [SourceRepository.episodes] call the detail page uses, so it works
/// for JS, CS, and the reading sources — Mihon and LNReader return a chapter
/// list from the same method. Best-effort — a per-show failure is swallowed so one dead
/// source can't block the rest.
class SubscriptionChecker {
  SubscriptionChecker(this._repo, this._store);

  /// The ROUTER, not the source repository.
  ///
  /// It dispatches on the url, so a `zm://` subscription reaches the metadata
  /// catalogue, which resolves the matched source itself. Asking
  /// [SourceRepository] directly threw `Provider not loaded: zm` for every
  /// metadata title — swallowed below, so the bell stored state and was then
  /// never checked again.
  final CatalogueRepository _repo;
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
                reading: sub.isReading,
              );
            }
            await _store.setCount(sub.sourceId, sub.url, count);
          }
        } catch (e) {
          // Dead/slow source — skip; retried next sweep. Logged because a
          // subscription that silently never fires is undiagnosable: the
          // `zm` breakage above sat behind this exact catch.
          AppLogger.instance.log(
            '[notify] check failed · ${sub.sourceId} · ${sub.title} · $e',
          );
        }
      }
    } finally {
      _running = false;
    }
  }
}
