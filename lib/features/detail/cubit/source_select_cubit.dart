import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/zmode/match_store.dart';
import '../../../core/zmode/source_matcher.dart';
import '../../../core/zmode/zmode_ids.dart';

/// Which installed source is preferred for Z Mode playback, and that source's
/// remembered match (or lack of one) for this title.
class SourceSelectState {
  const SourceSelectState({
    this.sources = const [],
    this.selectedId,
    this.match,
    this.loading = false,
    this.resolved = false,
  });

  /// The installed sources valid for this title's kind.
  final List<({String id, String name})> sources;

  /// Which of [sources] is preferred for this kind. Set synchronously from
  /// [ZSourcePrefs] — not from a live search.
  final String? selectedId;

  /// The selected source's remembered match, when [resolved] is true.
  final SourceMatch? match;

  /// True while [selectSource] is searching the newly picked source.
  final bool loading;

  /// Whether we know if the selected source has this title: a cached match or
  /// miss on disk, or a search the user triggered (source pick / Wrong title?).
  /// Playback still sweeps all sources at Play time regardless.
  final bool resolved;

  SourceSelectState copyWith({
    List<({String id, String name})>? sources,
    String? selectedId,
    SourceMatch? match,
    bool? loading,
    bool? resolved,
  }) =>
      SourceSelectState(
        sources: sources ?? this.sources,
        selectedId: selectedId ?? this.selectedId,
        match: match ?? this.match,
        loading: loading ?? this.loading,
        resolved: resolved ?? this.resolved,
      );
}

/// Backs the Detail screen's preferred-playback-source row: shows the global
/// per-kind pick and optional match status. Playback sweeps all sources at
/// tap time; this row is for preference and "Wrong title?" corrections.
class SourceSelectCubit extends Cubit<SourceSelectState> {
  SourceSelectCubit({
    required MatchStore store,
    required SourceMatcher matcher,
    required ZCanonical canonical,
    required List<({String id, String name})> sources,
    required String title,
    this.altTitle,
    this.malId,
  })  : _store = store,
       _matcher = matcher,
       _canonical = canonical,
       _title = title,
       super(_seed(store, matcher, canonical, sources));

  /// The first state, built from what is ALREADY on disk. Both reads are
  /// synchronous, so a title that has been opened before shows its source and
  /// episode count on the very first frame. Reading them after the sweep (as
  /// this used to) left the row blank for seconds while re-deriving an answer
  /// the store already had.
  static SourceSelectState _seed(
    MatchStore store,
    SourceMatcher matcher,
    ZCanonical canonical,
    List<({String id, String name})> sources,
  ) {
    final selected = matcher.selectedFor(canonical.kind);
    final match =
        selected == null ? null : store.get(canonical, selected);
    final resolved = selected != null &&
        (match != null || store.missedRecently(canonical, selected));
    return SourceSelectState(
      sources: sources,
      selectedId: selected,
      match: match,
      loading: false,
      resolved: resolved,
    );
  }

  final MatchStore _store;
  final SourceMatcher _matcher;
  final ZCanonical _canonical;
  final String _title;
  final String? altTitle;
  final int? malId;

  /// Keeps [state.sources] in sync with a live [SourceRepository] read.
  /// TV skips boot-time provider load, so the list at widget creation is
  /// often empty even after the user has installed sources.
  void syncSources(List<({String id, String name})> sources) {
    if (sources.length == state.sources.length &&
        sources.every((s) => state.sources.any((o) => o.id == s.id))) {
      return;
    }
    final selected = _matcher.selectedFor(_canonical.kind);
    final match =
        selected == null ? null : _store.get(_canonical, selected);
    final resolved = state.resolved ||
        (selected != null &&
            (match != null || _store.missedRecently(_canonical, selected)));
    emit(SourceSelectState(
      sources: sources,
      selectedId: selected,
      match: match ?? state.match,
      loading: state.loading,
      resolved: resolved,
    ));
  }

  /// Re-search the preferred source (e.g. after Wrong title? closed without
  /// pinning but changed the global pick). Not called on Detail open — Play
  /// sweeps all sources; this row only reflects prefs + cached matches.
  Future<void> load() async {
    if (state.sources.isEmpty) return;
    emit(state.copyWith(loading: true));
    final m = await _matcher.resolve(
      _canonical,
      title: _title,
      altTitle: altTitle,
      malId: malId,
    );
    if (isClosed) return;
    emit(SourceSelectState(
      sources: state.sources,
      selectedId: _matcher.selectedFor(_canonical.kind),
      match: m,
      loading: false,
      resolved: true,
    ));
  }

  Future<void> selectSource(String id) async {
    emit(SourceSelectState(
      sources: state.sources,
      selectedId: id,
      loading: true,
      resolved: state.resolved,
    ));
    await _matcher.selectSource(_canonical.kind, id);
    final m = await _matcher.resolve(
      _canonical,
      title: _title,
      altTitle: altTitle,
      malId: malId,
    );
    if (isClosed) return;
    emit(SourceSelectState(
      sources: state.sources,
      selectedId: id,
      match: m,
      loading: false,
      resolved: true,
    ));
  }

  void applyPinned(SourceMatch m) => emit(SourceSelectState(
        sources: state.sources,
        selectedId: m.sourceId,
        match: m,
        loading: false,
        resolved: true,
      ));
}
