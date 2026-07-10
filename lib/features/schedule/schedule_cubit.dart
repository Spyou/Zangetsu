import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
    this.errorSoon = false,
  });

  final List<AiringEntry> airingAll;

  /// All airing entries grouped by local day (the Anime tab).
  final Map<DateTime, List<AiringEntry>> airingByDay;

  /// Airing entries narrowed to anime the user tracks in My List, grouped by
  /// day (the My List tab). Precomputed so both tabs read state without either
  /// mutating the other's grouping.
  final Map<DateTime, List<AiringEntry>> myListByDay;

  final List<ComingSoonEntry> comingSoon;
  final bool loadingAiring;
  final bool loadingSoon;
  final bool errorAiring;
  final bool errorSoon;

  ScheduleState copyWith({
    List<AiringEntry>? airingAll,
    Map<DateTime, List<AiringEntry>>? airingByDay,
    Map<DateTime, List<AiringEntry>>? myListByDay,
    List<ComingSoonEntry>? comingSoon,
    bool? loadingAiring,
    bool? loadingSoon,
    bool? errorAiring,
    bool? errorSoon,
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
      );

  @override
  List<Object?> get props => [
        airingAll, airingByDay, myListByDay, comingSoon, loadingAiring,
        loadingSoon, errorAiring, errorSoon,
      ];
}

class ScheduleCubit extends Cubit<ScheduleState> {
  ScheduleCubit(this._airing, this._soon, this._myList)
      : super(const ScheduleState());

  final AiringService _airing;
  final ComingSoonService _soon;
  final MyListStore _myList;

  Future<void> load() async {
    await Future.wait([_loadAiring(), _loadSoon()]);
  }

  Future<void> refresh() => load();

  Future<void> _loadAiring() async {
    emit(state.copyWith(loadingAiring: true, errorAiring: false));
    final entries = await _airing.weekAiring();
    emit(state.copyWith(
      airingAll: entries,
      airingByDay: groupByLocalDay(entries),
      myListByDay: groupByLocalDay(filterByMalIds(entries, _myListMalIds())),
      loadingAiring: false,
      errorAiring: entries.isEmpty, // best-effort; empty week reads as "nothing"
    ));
  }

  Future<void> _loadSoon() async {
    emit(state.copyWith(loadingSoon: true, errorSoon: false));
    final soon = await _soon.upcoming();
    emit(state.copyWith(comingSoon: soon, loadingSoon: false, errorSoon: false));
  }

  Set<int> _myListMalIds() => <int>{
        for (final m in _myList.all())
          if (m.type == ProviderType.anime && m.malId != null) m.malId!,
      };
}
