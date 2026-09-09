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
    this.auto = false,
  });

  /// The installed sources valid for this title's kind.
  final List<({String id, String name})> sources;

  /// Which of [sources] is preferred for this kind. Set synchronously from
  /// [ZSourcePrefs] — not from a live search. While [auto] is true this is
  /// whichever candidate the last sweep actually matched, not a fixed pick.
  final String? selectedId;

  /// The selected source's remembered match, when [resolved] is true.
  final SourceMatch? match;

  /// True while [selectSource] is searching the newly picked source.
  final bool loading;

  /// Whether we know if the selected source has this title: a cached match or
  /// miss on disk, or a search the user triggered (source pick / Wrong title?).
  /// Playback still sweeps all sources at Play time regardless.
  final bool resolved;

  /// True when this kind is set to Auto Resolve — [selectedId] names whichever
  /// candidate last matched, not a fixed choice. A per-title pin still wins
  /// over this (see [SourceMatcher]), in which case this is false.
  final bool auto;

  SourceSelectState copyWith({
    List<({String id, String name})>? sources,
    String? selectedId,
    SourceMatch? match,
    bool? loading,
    bool? resolved,
    bool? auto,
  }) =>
      SourceSelectState(
        sources: sources ?? this.sources,
        selectedId: selectedId ?? this.selectedId,
        match: match ?? this.match,
        loading: loading ?? this.loading,
        resolved: resolved ?? this.resolved,
        auto: auto ?? this.auto,
      );
}

/// Backs the Detail screen's per-title source row: names whichever source
/// this title actually plays through — a pin on this title, else the kind
/// default, else Auto Resolve — and its match status. Picking a source here
/// pins it to THIS title only; it never changes any other title's source.
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
    final selected = matcher.sourceForTitle(canonical);
    if (selected == null) {
      // Auto Resolve — read whichever candidate's cache already has this
      // title, in priority order, without a network sweep on this frame.
      // Name the source Auto Resolve would actually use, not merely the first
      // one holding a cached match. The one that last PLAYED this title is the
      // resolver's own first choice (see PlaybackResolver._orderedCandidates),
      // so anything else here would name a source the viewer never gets — and
      // the row's per-source actions, Cloudflare solve included, act on this
      // id, so naming the wrong one points them at the wrong site.
      final played = store.lastPlayed(canonical);
      final order = [
        ...sources.where((s) => s.id == played),
        ...sources.where((s) => s.id != played),
      ];
      for (final s in order) {
        final m = store.get(canonical, s.id);
        if (m != null) {
          return SourceSelectState(
            sources: sources,
            selectedId: s.id,
            match: m,
            loading: false,
            resolved: true,
            auto: true,
          );
        }
      }
      return SourceSelectState(sources: sources, loading: false, auto: true);
    }
    final match = store.get(canonical, selected);
    final resolved = match != null || store.missedRecently(canonical, selected);
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
    final selectedFromMatcher = _matcher.sourceForTitle(_canonical);
    final auto = selectedFromMatcher == null;
    // Auto keeps whatever the last sweep found — this sync only refreshes
    // the installed-sources list, it does not re-sweep.
    final selected = auto ? state.selectedId : selectedFromMatcher;
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
      auto: auto,
    ));
  }

  /// Re-search this title's source (e.g. after Wrong title? closed without
  /// pinning but changed the kind default). Not called on Detail open — Play
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
    final auto = _matcher.sourceForTitle(_canonical) == null;
    emit(SourceSelectState(
      sources: state.sources,
      selectedId: auto ? m?.sourceId : _matcher.sourceForTitle(_canonical),
      match: m,
      loading: false,
      resolved: true,
      auto: auto,
    ));
  }

  /// The user picked [id] for THIS title only — searches it fresh and pins
  /// whatever it finds, without changing any other title of this kind.
  Future<void> selectSource(String id) async {
    emit(SourceSelectState(
      sources: state.sources,
      selectedId: id,
      loading: true,
      resolved: state.resolved,
    ));
    final m = await _matcher.pinTitleToSource(
      _canonical,
      id,
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

  /// Drop this title's own pin AND the kind's explicit default — genuinely
  /// back to sweeping, not just to whichever fixed source the kind default
  /// names.
  Future<void> selectAuto() async {
    emit(SourceSelectState(
      sources: state.sources,
      selectedId: null,
      loading: true,
      resolved: state.resolved,
      auto: true,
    ));
    await _matcher.clearAuto(_canonical);
    final m = await _matcher.resolve(
      _canonical,
      title: _title,
      altTitle: altTitle,
      malId: malId,
    );
    if (isClosed) return;
    emit(SourceSelectState(
      sources: state.sources,
      selectedId: m?.sourceId,
      match: m,
      loading: false,
      resolved: true,
      auto: true,
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
