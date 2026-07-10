import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/schedule/airing_service.dart';
import '../../core/schedule/coming_soon_service.dart';
import '../../core/schedule/schedule_models.dart';

enum ScheduleFilter { all, myList }

class ScheduleState extends Equatable {
  const ScheduleState({
    this.airingAll = const [],
    this.airingByDay = const {},
    this.comingSoon = const [],
    this.loadingAiring = true,
    this.loadingSoon = true,
    this.errorAiring = false,
    this.errorSoon = false,
    this.filter = ScheduleFilter.all,
  });

  final List<AiringEntry> airingAll;
  final Map<DateTime, List<AiringEntry>> airingByDay;
  final List<ComingSoonEntry> comingSoon;
  final bool loadingAiring;
  final bool loadingSoon;
  final bool errorAiring;
  final bool errorSoon;
  final ScheduleFilter filter;

  ScheduleState copyWith({
    List<AiringEntry>? airingAll,
    Map<DateTime, List<AiringEntry>>? airingByDay,
    List<ComingSoonEntry>? comingSoon,
    bool? loadingAiring,
    bool? loadingSoon,
    bool? errorAiring,
    bool? errorSoon,
    ScheduleFilter? filter,
  }) =>
      ScheduleState(
        airingAll: airingAll ?? this.airingAll,
        airingByDay: airingByDay ?? this.airingByDay,
        comingSoon: comingSoon ?? this.comingSoon,
        loadingAiring: loadingAiring ?? this.loadingAiring,
        loadingSoon: loadingSoon ?? this.loadingSoon,
        errorAiring: errorAiring ?? this.errorAiring,
        errorSoon: errorSoon ?? this.errorSoon,
        filter: filter ?? this.filter,
      );

  @override
  List<Object?> get props => [
        airingAll, airingByDay, comingSoon, loadingAiring, loadingSoon,
        errorAiring, errorSoon, filter,
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

  void setFilter(ScheduleFilter f) {
    emit(state.copyWith(filter: f, airingByDay: _regroup(state.airingAll, f)));
  }

  Future<void> _loadAiring() async {
    emit(state.copyWith(loadingAiring: true, errorAiring: false));
    final entries = await _airing.weekAiring();
    emit(state.copyWith(
      airingAll: entries,
      airingByDay: _regroup(entries, state.filter),
      loadingAiring: false,
      errorAiring: entries.isEmpty, // best-effort; empty week reads as "nothing"
    ));
  }

  Future<void> _loadSoon() async {
    emit(state.copyWith(loadingSoon: true, errorSoon: false));
    final soon = await _soon.upcoming();
    emit(state.copyWith(comingSoon: soon, loadingSoon: false, errorSoon: false));
  }

  Map<DateTime, List<AiringEntry>> _regroup(
      List<AiringEntry> all, ScheduleFilter f) {
    if (f == ScheduleFilter.myList) {
      final ids = <int>{
        for (final m in _myList.all())
          if (m.type == ProviderType.anime && m.malId != null) m.malId!,
      };
      return groupByLocalDay(filterByMalIds(all, ids));
    }
    return groupByLocalDay(all);
  }
}
