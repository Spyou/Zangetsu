import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/tracker/tracker.dart';
import 'my_list_cubit.dart';

/// Which "source" the My List screen is currently showing: the app's own
/// My List, or one connected tracker's full library.
sealed class TrackerListSource {
  const TrackerListSource();
}

/// The app's own saved list — rendered by the existing [MyListCubit]; this
/// cubit holds NO data for it (don't duplicate that store).
class MyListSource extends TrackerListSource {
  const MyListSource();
}

/// A specific tracker's library (AniList / MAL / Simkl).
class TrackerSource extends TrackerListSource {
  const TrackerSource(this.tracker);
  final Tracker tracker;
}

/// Load lifecycle for a tracker's fetched library.
enum TrackerListStatus { idle, loading, ready, error }

/// State of the My List source-switcher: the active [source], plus — when a
/// tracker is active — its fetched entries and load status. When [source] is a
/// [MyListSource] the grid is driven by the existing [MyListCubit] instead, so
/// [entries]/[status] are irrelevant.
class TrackerListState {
  const TrackerListState({
    required this.source,
    this.status = TrackerListStatus.idle,
    this.entries = const [],
  });

  final TrackerListSource source;
  final TrackerListStatus status;
  final List<MyListEntry> entries;

  bool get isMyList => source is MyListSource;

  /// The active tracker, or null when My List is selected.
  Tracker? get tracker =>
      source is TrackerSource ? (source as TrackerSource).tracker : null;

  TrackerListState copyWith({
    TrackerListSource? source,
    TrackerListStatus? status,
    List<MyListEntry>? entries,
  }) => TrackerListState(
    source: source ?? this.source,
    status: status ?? this.status,
    entries: entries ?? this.entries,
  );
}

/// Drives the My List screen's source switcher. Holds the selected source and,
/// for a tracker, fetches its library once and caches it for the session (a
/// re-select doesn't refetch). [refresh] re-calls `tracker.fetchList()` for
/// pull-to-refresh. Selecting [MyListSource] just flips back to the existing
/// [MyListCubit]-driven grid — no data is held here for it.
class TrackerListCubit extends Cubit<TrackerListState> {
  TrackerListCubit()
    : super(const TrackerListState(source: MyListSource()));

  /// Per-session cache of a tracker's mapped entries, keyed by tracker. Lets
  /// switching between sources re-show a list instantly without refetching.
  final Map<Tracker, List<MyListEntry>> _cache = {};

  /// Switch back to the app's own My List (rendered by [MyListCubit]).
  void selectMyList() {
    if (state.isMyList) return;
    emit(const TrackerListState(source: MyListSource()));
  }

  /// Switch to [tracker]'s library. Uses the session cache when present;
  /// otherwise kicks off a fetch.
  void selectTracker(Tracker tracker) {
    final cached = _cache[tracker];
    if (cached != null) {
      emit(TrackerListState(
        source: TrackerSource(tracker),
        status: TrackerListStatus.ready,
        entries: cached,
      ));
      return;
    }
    emit(TrackerListState(
      source: TrackerSource(tracker),
      status: TrackerListStatus.loading,
    ));
    _fetch(tracker);
  }

  /// Re-fetch the active tracker's list (pull-to-refresh). No-op for My List.
  Future<void> refresh() async {
    final tracker = state.tracker;
    if (tracker == null) return;
    await _fetch(tracker);
  }

  Future<void> _fetch(Tracker tracker) async {
    try {
      final raw = await tracker.fetchList();
      if (isClosed) return;
      final entries = [
        for (final t in raw) MyListEntry(t.item, t.status),
      ];
      _cache[tracker] = entries;
      // Ignore a result that lands after the user switched away.
      if (state.tracker != tracker) return;
      emit(state.copyWith(
        status: TrackerListStatus.ready,
        entries: entries,
      ));
    } catch (_) {
      if (isClosed || state.tracker != tracker) return;
      emit(state.copyWith(status: TrackerListStatus.error));
    }
  }
}
