import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/schedule/airing_service.dart';
import '../../core/schedule/coming_soon_service.dart';
import '../../core/schedule/schedule_models.dart';

/// Whether the redesigned phone Schedule shows a 7-day header or a full-month
/// calendar grid. (The TV screen ignores this and stays week-only.)
enum ScheduleView { week, month }

class ScheduleState extends Equatable {
  const ScheduleState({
    this.airingAll = const [],
    this.airingByDay = const {},
    this.myListByDay = const {},
    this.comingSoon = const [],
    this.loadingAiring = true,
    this.loadingSoon = true,
    this.errorAiring = false,
    this.errorSoon = false,
    // ── redesign additions (phone) ──
    this.view = ScheduleView.week,
    this.monthAnchor,
    this.selectedDay,
    this.myListOnly = false,
    this.monthAiringByDay = const {},
    this.followedMalIds = const {},
    this.soonByDay = const {},
    this.loadingMonth = false,
    this.errorMonth = false,
  });

  final List<AiringEntry> airingAll;

  /// All week airing entries grouped by local day (the week view / TV Anime).
  final Map<DateTime, List<AiringEntry>> airingByDay;

  /// Week airing narrowed to tracked anime, grouped by day (TV My List tab).
  /// Kept for the unchanged TV screen; the phone redesign uses [followedMalIds]
  /// with [myListOnly] instead.
  final Map<DateTime, List<AiringEntry>> myListByDay;

  final List<ComingSoonEntry> comingSoon;
  final bool loadingAiring;
  final bool loadingSoon;
  final bool errorAiring;
  final bool errorSoon;

  // ── redesign additions ──
  final ScheduleView view;

  /// First-of-month for the displayed month (month view). Null until first load.
  final DateTime? monthAnchor;

  /// The day whose episode list is shown. Null until first load (→ today).
  final DateTime? selectedDay;

  /// My List filter toggle — when on, the anime list/grid narrows to shows the
  /// user follows.
  final bool myListOnly;

  /// Month airing grouped by local day (month view). Loaded on demand.
  final Map<DateTime, List<AiringEntry>> monthAiringByDay;

  /// MAL ids of anime in My List — drives the green "you follow this" dot and
  /// the [myListOnly] filter.
  final Set<int> followedMalIds;

  /// Coming-soon movies/TV grouped by local release day (both views).
  final Map<DateTime, List<ComingSoonEntry>> soonByDay;

  final bool loadingMonth;
  final bool errorMonth;

  ScheduleState copyWith({
    List<AiringEntry>? airingAll,
    Map<DateTime, List<AiringEntry>>? airingByDay,
    Map<DateTime, List<AiringEntry>>? myListByDay,
    List<ComingSoonEntry>? comingSoon,
    bool? loadingAiring,
    bool? loadingSoon,
    bool? errorAiring,
    bool? errorSoon,
    ScheduleView? view,
    DateTime? monthAnchor,
    DateTime? selectedDay,
    bool? myListOnly,
    Map<DateTime, List<AiringEntry>>? monthAiringByDay,
    Set<int>? followedMalIds,
    Map<DateTime, List<ComingSoonEntry>>? soonByDay,
    bool? loadingMonth,
    bool? errorMonth,
  }) =>
      ScheduleState(
        airingAll: airingAll ?? this.airingAll,
        airingByDay: airingByDay ?? this.airingByDay,
        myListByDay: myListByDay ?? this.myListByDay,
        comingSoon: comingSoon ?? this.comingSoon,
        loadingAiring: loadingAiring ?? this.loadingAiring,
        loadingSoon: loadingSoon ?? this.loadingSoon,
        errorAiring: errorAiring ?? this.errorAiring,
        errorSoon: errorSoon ?? this.errorSoon,
        view: view ?? this.view,
        monthAnchor: monthAnchor ?? this.monthAnchor,
        selectedDay: selectedDay ?? this.selectedDay,
        myListOnly: myListOnly ?? this.myListOnly,
        monthAiringByDay: monthAiringByDay ?? this.monthAiringByDay,
        followedMalIds: followedMalIds ?? this.followedMalIds,
        soonByDay: soonByDay ?? this.soonByDay,
        loadingMonth: loadingMonth ?? this.loadingMonth,
        errorMonth: errorMonth ?? this.errorMonth,
      );

  @override
  List<Object?> get props => [
        airingAll, airingByDay, myListByDay, comingSoon, loadingAiring,
        loadingSoon, errorAiring, errorSoon, view, monthAnchor, selectedDay,
        myListOnly, monthAiringByDay, followedMalIds, soonByDay, loadingMonth,
        errorMonth,
      ];
}

class ScheduleCubit extends Cubit<ScheduleState> {
  ScheduleCubit(
    this._airing,
    this._soon,
    this._myList, {
    List<Duration>? retryDelays,
  })  : _retryDelays = retryDelays ?? _defaultRetryDelays,
        super(const ScheduleState());

  final AiringService _airing;
  final ComingSoonService _soon;
  final MyListStore _myList;

  // Backoff between retries when a fetch comes back empty. Both services
  // already swallow errors and return [] on failure, and neither AniList's
  // weekly airing nor TMDB's upcoming window is ever legitimately empty — so
  // an empty result means the request failed (e.g. network not ready at the
  // startup load) and is worth retrying. Stays on the loading spinner across
  // retries rather than flashing a false "nothing here". Injectable so tests
  // can pass `const []` and skip the real delays.
  static const List<Duration> _defaultRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];
  final List<Duration> _retryDelays;

  bool _inFlight = false;

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
  static DateTime _firstOfMonth(DateTime d) => DateTime(d.year, d.month, 1);

  Future<void> load() async {
    if (_inFlight) return; // don't stack retry loops (e.g. refresh mid-retry)
    _inFlight = true;
    // Seed today/this-month on the first load so the grid + selection resolve.
    final now = DateTime.now();
    if (state.selectedDay == null) {
      emit(state.copyWith(
        selectedDay: _dayOf(now),
        monthAnchor: _firstOfMonth(now),
      ));
    }
    try {
      await Future.wait([_loadAiring(), _loadSoon()]);
    } finally {
      _inFlight = false;
    }
  }

  Future<void> refresh() async {
    await load();
    // Also refresh the month if the user is currently viewing one.
    if (state.view == ScheduleView.month && state.monthAnchor != null) {
      await _loadMonth(state.monthAnchor!);
    }
  }

  /// Switch the week/month toggle. Entering month lazily loads its data.
  Future<void> setView(ScheduleView view) async {
    if (view == state.view) return;
    emit(state.copyWith(view: view));
    if (view == ScheduleView.month) {
      final anchor = state.monthAnchor ?? _firstOfMonth(DateTime.now());
      if (state.monthAiringByDay.isEmpty) await _loadMonth(anchor);
    }
  }

  /// Move to another month (month view) and load it.
  Future<void> goToMonth(DateTime anchorLocal) async {
    final anchor = _firstOfMonth(anchorLocal);
    // Selecting a new month: land on today if it's this month, else the 1st.
    final now = DateTime.now();
    final sel = (anchor.year == now.year && anchor.month == now.month)
        ? _dayOf(now)
        : anchor;
    emit(state.copyWith(monthAnchor: anchor, selectedDay: sel));
    await _loadMonth(anchor);
  }

  void selectDay(DateTime day) =>
      emit(state.copyWith(selectedDay: _dayOf(day)));

  void toggleMyListOnly() =>
      emit(state.copyWith(myListOnly: !state.myListOnly));

  Future<void> _loadAiring() async {
    emit(state.copyWith(loadingAiring: true, errorAiring: false));
    var entries = await _airing.weekAiring();
    for (var i = 0; entries.isEmpty && i < _retryDelays.length; i++) {
      await Future<void>.delayed(_retryDelays[i]);
      if (isClosed) return; // widget disposed mid-retry
      entries = await _airing.weekAiring();
    }
    if (isClosed) return;
    final followed = _myListMalIds();
    emit(state.copyWith(
      airingAll: entries,
      airingByDay: groupByLocalDay(entries),
      myListByDay: groupByLocalDay(filterByMalIds(entries, followed)),
      followedMalIds: followed,
      loadingAiring: false,
      errorAiring: entries.isEmpty, // still empty after retries → genuine miss
    ));
  }

  Future<void> _loadSoon() async {
    emit(state.copyWith(loadingSoon: true, errorSoon: false));
    var soon = await _soon.upcoming();
    for (var i = 0; soon.isEmpty && i < _retryDelays.length; i++) {
      await Future<void>.delayed(_retryDelays[i]);
      if (isClosed) return;
      soon = await _soon.upcoming();
    }
    if (isClosed) return;
    emit(state.copyWith(
      comingSoon: soon,
      soonByDay: groupSoonByLocalDay(soon),
      loadingSoon: false,
      errorSoon: soon.isEmpty,
    ));
  }

  Future<void> _loadMonth(DateTime anchor) async {
    emit(state.copyWith(loadingMonth: true, errorMonth: false));
    var entries = await _airing.monthAiring(anchor);
    for (var i = 0; entries.isEmpty && i < _retryDelays.length; i++) {
      await Future<void>.delayed(_retryDelays[i]);
      if (isClosed) return;
      entries = await _airing.monthAiring(anchor);
    }
    if (isClosed) return;
    emit(state.copyWith(
      monthAiringByDay: groupByLocalDay(entries),
      loadingMonth: false,
      errorMonth: entries.isEmpty,
    ));
  }

  Set<int> _myListMalIds() => <int>{
        for (final m in _myList.all())
          if (m.type == ProviderType.anime && m.malId != null) m.malId!,
      };
}
