import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/media_item.dart' show normalizeTitle;
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/schedule/airing_service.dart';
import '../../core/schedule/coming_soon_service.dart';
import '../../core/schedule/schedule_models.dart';

class ScheduleState extends Equatable {
  const ScheduleState({
    this.airingAll = const [],
    this.airingByDay = const {},
    this.myListByDay = const {},
    this.comingSoon = const [],
    this.loadingAiring = true,
    this.loadingSoon = true,
    this.errorAiring = false,
    this.offline = false,
    this.errorSoon = false,
    // ── redesign additions (phone) ──
    this.selectedDay,
    this.myListOnly = false,
    this.followed = const FollowedShows(),
    this.soonByDay = const {},
  });

  final List<AiringEntry> airingAll;

  /// All week airing entries grouped by local day (the week view / TV Anime).
  final Map<DateTime, List<AiringEntry>> airingByDay;

  /// Week airing narrowed to tracked anime, grouped by day (TV My List tab).
  /// Kept for the unchanged TV screen; the phone redesign uses [followed]
  /// with [myListOnly] instead.
  final Map<DateTime, List<AiringEntry>> myListByDay;

  final List<ComingSoonEntry> comingSoon;
  final bool loadingAiring;
  final bool loadingSoon;
  final bool errorAiring;

  /// Nothing reached the network on the last load. Distinct from an empty
  /// schedule: "nothing airing this week" is a claim, and it should not be
  /// made on a dropped connection.
  final bool offline;
  final bool errorSoon;

  // ── redesign additions ──
  /// The day whose episode list is shown. Null until first load (→ today).
  final DateTime? selectedDay;

  /// My List filter toggle — when on, the anime list/grid narrows to shows the
  /// user follows.
  final bool myListOnly;

  /// MAL ids of anime in My List — drives the green "you follow this" dot and
  /// the [myListOnly] filter. Matches on MAL id OR title — see [FollowedShows].
  final FollowedShows followed;

  /// Coming-soon movies/TV grouped by local release day (both views).
  final Map<DateTime, List<ComingSoonEntry>> soonByDay;

  ScheduleState copyWith({
    List<AiringEntry>? airingAll,
    Map<DateTime, List<AiringEntry>>? airingByDay,
    Map<DateTime, List<AiringEntry>>? myListByDay,
    List<ComingSoonEntry>? comingSoon,
    bool? loadingAiring,
    bool? loadingSoon,
    bool? errorAiring,
    bool? offline,
    bool? errorSoon,
    DateTime? selectedDay,
    bool? myListOnly,
    FollowedShows? followed,
    Map<DateTime, List<ComingSoonEntry>>? soonByDay,
  }) =>
      ScheduleState(
        airingAll: airingAll ?? this.airingAll,
        airingByDay: airingByDay ?? this.airingByDay,
        myListByDay: myListByDay ?? this.myListByDay,
        comingSoon: comingSoon ?? this.comingSoon,
        loadingAiring: loadingAiring ?? this.loadingAiring,
        loadingSoon: loadingSoon ?? this.loadingSoon,
        errorAiring: errorAiring ?? this.errorAiring,
        offline: offline ?? this.offline,
        errorSoon: errorSoon ?? this.errorSoon,
        selectedDay: selectedDay ?? this.selectedDay,
        myListOnly: myListOnly ?? this.myListOnly,
        followed: followed ?? this.followed,
        soonByDay: soonByDay ?? this.soonByDay,
      );

  @override
  List<Object?> get props => [
        airingAll, airingByDay, myListByDay, comingSoon, loadingAiring,
        loadingSoon, errorAiring, errorSoon, offline, selectedDay,
        myListOnly, followed, soonByDay,
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

  Future<void> load() async {
    if (_inFlight) return; // don't stack retry loops (e.g. refresh mid-retry)
    _inFlight = true;
    // Seed today on the first load so the day strip has a selection.
    final now = DateTime.now();
    if (state.selectedDay == null) {
      emit(state.copyWith(selectedDay: _dayOf(now)));
    }
    try {
      await Future.wait([_loadAiring(), _loadSoon()]);
    } finally {
      _inFlight = false;
    }
  }

  Future<void> refresh() => load();

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
    final followed = _followedShows();
    emit(state.copyWith(
      airingAll: entries,
      airingByDay: groupByLocalDay(entries),
      myListByDay: groupByLocalDay(filterByFollowed(entries, followed)),
      followed: followed,
      loadingAiring: false,
      errorAiring: entries.isEmpty, // still empty after retries → genuine miss
      offline: entries.isEmpty && _airing.lastFailureOffline,
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
      offline: soon.isEmpty && _soon.lastFailureOffline,
    ));
  }

  /// What the My List filter matches against.
  ///
  /// Both ids AND titles: most list entries have no malId (it only arrives with
  /// metadata enrichment), so an id-only set was usually empty and the filter
  /// hid everything.
  FollowedShows _followedShows() {
    final mine =
        _myList.all().where((m) => m.type == ProviderType.anime).toList();
    return FollowedShows(
      malIds: {
        for (final m in mine)
          if (m.malId != null) m.malId!,
      },
      titles: {
        for (final m in mine) ...[
          normalizeTitle(m.title),
          if (m.englishTitle != null) normalizeTitle(m.englishTitle!),
        ],
      }..removeWhere((t) => t.isEmpty),
    );
  }
}
