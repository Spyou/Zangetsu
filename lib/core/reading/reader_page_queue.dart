import 'dart:async';
import 'dart:collection';

/// How badly a page is wanted. Higher wins.
enum PagePriority {
  /// Read ahead. Queued behind anything the reader is actually waiting for.
  adjacent(0),

  /// The page on screen.
  current(1),

  /// A person tapped retry, so it jumps everything.
  retry(2);

  const PagePriority(this.rank);
  final int rank;
}

/// Fetches page images **one at a time, in the order they are wanted**.
///
/// The reader used to fire its whole preload window at once and let the
/// network decide what arrived first. On a fast source that is invisible. On a
/// slow or rate-limited one — measured at 8 to 19 SECONDS per request on a
/// real source — it means the page you are staring at is queued behind four
/// pages you have not reached yet, and can quite easily arrive last. Pages
/// appeared in whatever order they happened to finish.
///
/// So requests go through a single worker and a priority queue, the way the
/// reference Android reader does it: the visible page first, then the ones
/// ahead of it in order, one at a time. Ties break on insertion order, which
/// is what actually makes pages appear top to bottom instead of scattered.
///
/// Scrolling away from a page that has not started yet drops it — see
/// [keepOnly] — so the queue never spends the connection on pages nobody is
/// heading towards any more.
class ReaderPageQueue {
  ReaderPageQueue({required this.fetch});

  /// Does the actual work for one page. Errors are swallowed by the queue —
  /// a page that will not load is the image widget's problem to show.
  final Future<void> Function(String key) fetch;

  final _pending = SplayTreeSet<_Entry>();
  final _queued = <String>{};
  final _done = <String>{};
  var _seq = 0;
  var _busy = false;
  var _closed = false;

  /// Pages waiting, in the order they will be fetched. Test seam.
  List<String> get pendingKeys => [for (final e in _pending) e.key];

  /// Adds [key] unless it is already queued or already fetched.
  ///
  /// Re-queueing at a HIGHER priority promotes it: scrolling onto a page that
  /// was merely read-ahead should not leave it stuck behind other read-ahead.
  void add(String key, PagePriority priority) {
    if (_closed || _done.contains(key)) return;
    if (_queued.contains(key)) {
      final existing = _pending.firstWhere(
        (e) => e.key == key,
        orElse: () => _Entry('', PagePriority.adjacent, -1),
      );
      if (existing.seq < 0 || existing.priority.rank >= priority.rank) return;
      _pending.remove(existing);
      _pending.add(_Entry(key, priority, existing.seq));
      return;
    }
    _queued.add(key);
    _pending.add(_Entry(key, priority, _seq++));
    unawaited(_pump());
  }

  /// Drops anything still WAITING whose key isn't in [keep]. The fetch already
  /// in flight is left alone — it is nearly always the page being looked at,
  /// and cancelling a part-finished download just to start it again later is
  /// how you make a slow source slower.
  void keepOnly(Set<String> keep) {
    if (_closed) return;
    _pending.removeWhere((e) {
      final drop = !keep.contains(e.key);
      if (drop) _queued.remove(e.key);
      return drop;
    });
  }

  /// Forget that [key] was fetched, so it can be requested again.
  void forget(String key) => _done.remove(key);

  void dispose() {
    _closed = true;
    _pending.clear();
    _queued.clear();
  }

  Future<void> _pump() async {
    if (_busy || _closed) return;
    _busy = true;
    try {
      while (!_closed && _pending.isNotEmpty) {
        final next = _pending.first;
        _pending.remove(next);
        _queued.remove(next.key);
        try {
          await fetch(next.key);
        } catch (_) {
          // Best effort: the page shows its own error state.
        }
        _done.add(next.key);
      }
    } finally {
      _busy = false;
    }
  }
}

/// Ordered by priority first, then by when it was asked for. The sequence
/// number is what keeps equal-priority pages arriving top to bottom.
class _Entry implements Comparable<_Entry> {
  const _Entry(this.key, this.priority, this.seq);

  final String key;
  final PagePriority priority;
  final int seq;

  @override
  int compareTo(_Entry other) {
    final p = other.priority.rank.compareTo(priority.rank);
    return p != 0 ? p : seq.compareTo(other.seq);
  }

  @override
  bool operator ==(Object other) => other is _Entry && other.seq == seq;

  @override
  int get hashCode => seq.hashCode;
}
