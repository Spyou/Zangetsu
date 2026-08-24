import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/anilist/anilist_service.dart';
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
    this.customListNames = const [],
  });

  final TrackerListSource source;
  final TrackerListStatus status;
  final List<MyListEntry> entries;

  /// The tracker's OWN custom lists, straight from the account rather than
  /// inferred from [entries]. Taken from the source so a list that's been
  /// created but has nothing in it still gets a tab — deriving from entries
  /// alone made a new list invisible until something was filed into it.
  ///
  /// AniList only; empty for MAL and Simkl, which have no such concept.
  final List<String> customListNames;

  bool get isMyList => source is MyListSource;

  /// The active tracker, or null when My List is selected.
  Tracker? get tracker =>
      source is TrackerSource ? (source as TrackerSource).tracker : null;

  TrackerListState copyWith({
    TrackerListSource? source,
    TrackerListStatus? status,
    List<MyListEntry>? entries,
    List<String>? customListNames,
  }) => TrackerListState(
    source: source ?? this.source,
    status: status ?? this.status,
    entries: entries ?? this.entries,
    customListNames: customListNames ?? this.customListNames,
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
        // Carry the names over. Emitting a bare state dropped them, so the
        // custom-list tabs disappeared every time you switched back to this
        // tracker and only returned after a full reload.
        customListNames: _nameCache[tracker] ?? const [],
      ));
      // Show the cached copy immediately, then quietly re-read. Without this
      // the session cache never expires: a title filed into a custom list on
      // the AniList website (or from another device) kept reading as 0 here
      // until the user happened to pull-to-refresh.
      unawaited(_fetch(tracker));
      return;
    }
    emit(TrackerListState(
      source: TrackerSource(tracker),
      status: TrackerListStatus.loading,
    ));
    unawaited(_fetch(tracker));
  }

  /// Re-fetch the active tracker's list (pull-to-refresh). No-op for My List.
  Future<void> refresh() async {
    final tracker = state.tracker;
    if (tracker == null) return;
    await _fetch(tracker);
  }

  /// Cached per tracker: the names change only when the user edits them, and
  /// the un-cached version re-queried AniList on every load — five times in
  /// half a minute, by the log.
  final Map<Tracker, List<String>> _nameCache = {};

  /// Fetches the tracker's own custom list names and folds them into state.
  /// Never throws into the caller: the tabs are a bonus, the library is not.
  Future<void> _loadCustomListNames(Tracker tracker) async {
    if (tracker is! AniListService) return;
    final cached = _nameCache[tracker];
    if (cached != null) {
      if (!isClosed && state.tracker == tracker) {
        emit(state.copyWith(customListNames: cached));
      }
      return;
    }
    try {
      final names = await tracker.customListNames();
      _nameCache[tracker] = names;
      if (isClosed || state.tracker != tracker) return;
      emit(state.copyWith(customListNames: names));
    } catch (_) {
      // Leave the tabs off rather than disturbing a library that loaded fine.
    }
  }

  /// Drop the cached names so the next load re-reads them — used after the
  /// user creates a list, which is the only thing that changes them.
  void invalidateCustomListNames() => _nameCache.clear();

  Future<void> _fetch(Tracker tracker) async {
    try {
      final raw = await tracker.fetchList();
      if (isClosed) return;
      final entries = [
        for (final t in raw)
          MyListEntry(t.item, t.status,
              progress: t.progress,
              score: t.score,
              tmdbIsTv: t.tmdbIsTv,
              updatedAt: t.updatedAt,
              customLists: t.customLists),
      ];
      _cache[tracker] = entries;
      if (isClosed) return;
      // Ignore a result that lands after the user switched away.
      if (state.tracker != tracker) return;
      emit(state.copyWith(
        status: TrackerListStatus.ready,
        entries: entries,
      ));
      // The account's own list names arrive SEPARATELY, after the library is
      // already on screen. Awaiting them inline made the whole tab wait on a
      // second request it doesn't need — it looked unresponsive, and the
      // entries had been ready the whole time.
      unawaited(_loadCustomListNames(tracker));
    } catch (_) {
      if (isClosed || state.tracker != tracker) return;
      emit(state.copyWith(status: TrackerListStatus.error));
    }
  }
}
