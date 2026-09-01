import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/zmode/match_store.dart';
import '../../../core/zmode/source_matcher.dart';
import '../../../core/zmode/zmode_ids.dart';

/// Which installed source plays a Z Mode title, and that source's remembered
/// match (or lack of one).
class SourceSelectState {
  const SourceSelectState({
    this.sources = const [],
    this.selectedId,
    this.match,
    this.loading = true,
  });

  /// The installed sources valid for this title's kind.
  final List<({String id, String name})> sources;

  /// Which of [sources] plays this title. Null until the first resolve
  /// completes.
  final String? selectedId;

  /// The selected source's match. Null while loading, or when the selected
  /// source genuinely doesn't have this title — the honest empty state.
  final SourceMatch? match;

  final bool loading;
}

/// Backs the Detail screen's source selector row: resolves/tracks which
/// source plays a title, and lets the user switch it. Each source in
/// [SourceSelectState.sources] keeps its own remembered match in
/// [MatchStore] — switching the selection never touches another source's.
class SourceSelectCubit extends Cubit<SourceSelectState> {
  SourceSelectCubit({
    required MatchStore store,
    required SourceMatcher matcher,
    required ZCanonical canonical,
    required List<({String id, String name})> sources,
    required String title,
    this.altTitle,
    this.malId,
  })  : _matcher = matcher,
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
    // Both reads are synchronous, so the row names its source on the very
    // first frame — for every title, including one never opened before. Only
    // whether that source HAS this title still has to be looked up.
    final selected = matcher.selectedFor(canonical.kind);
    return SourceSelectState(
      sources: sources,
      selectedId: selected,
      match: selected == null ? null : store.get(canonical, selected),
      loading: sources.isNotEmpty,
    );
  }

  final SourceMatcher _matcher;
  final ZCanonical _canonical;
  final String _title;
  final String? altTitle;
  final int? malId;

  /// Resolves the current selection (or picks one, sweeping the candidates)
  /// and reflects it. A no-op when there's nothing to select from.
  Future<void> load() async {
    if (state.sources.isEmpty) return;
    final m = await _matcher.resolve(_canonical, title: _title, altTitle: altTitle, malId: malId);
    if (isClosed) return;
    emit(SourceSelectState(
      sources: state.sources,
      selectedId: _matcher.selectedFor(_canonical.kind),
      match: m,
      loading: false,
    ));
  }

  /// The user picked a different source in the picker: it becomes the
  /// remembered selection, and its own match (or honest lack of one) resolves.
  /// Picking a source is global for this kind, not a note about this title:
  /// every other title of the same kind opens on it from now on.
  Future<void> selectSource(String id) async {
    emit(SourceSelectState(sources: state.sources, selectedId: id, loading: true));
    await _matcher.selectSource(_canonical.kind, id);
    final m = await _matcher.resolve(_canonical, title: _title, altTitle: altTitle, malId: malId);
    if (isClosed) return;
    emit(SourceSelectState(sources: state.sources, selectedId: id, match: m, loading: false));
  }

  /// "Wrong title?" just pinned [m] for the selected source — reflect it
  /// directly, no re-search needed.
  void applyPinned(SourceMatch m) => emit(SourceSelectState(
    sources: state.sources, selectedId: m.sourceId, match: m, loading: false,
  ));
}
