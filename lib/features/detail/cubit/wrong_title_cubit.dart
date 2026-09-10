import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/repository/source_repository.dart';
import '../../../core/zmode/match_store.dart';
import '../../../core/zmode/source_matcher.dart';
import '../../../core/zmode/zmode_ids.dart';

class WrongTitleState {
  const WrongTitleState({
    this.results = const [],
    this.loading = false,
    this.query = '',
  });

  final List<MediaItem> results;
  final bool loading;

  /// What the running search is for. Shown while it runs, so a slow source
  /// says what it is doing instead of only spinning.
  final String query;

  WrongTitleState copyWith({
    List<MediaItem>? results,
    bool? loading,
    String? query,
  }) => WrongTitleState(
    results: results ?? this.results,
    loading: loading ?? this.loading,
    query: query ?? this.query,
  );
}

/// Manual re-match against one source: search it and pin the right result.
/// The source can be changed from inside the sheet — a title missing from one
/// source is the most likely moment to want a different one, and backing out
/// to change it and coming back is the long way round.
class WrongTitleCubit extends Cubit<WrongTitleState> {
  WrongTitleCubit({
    required SourceRepository sources,
    required SourceMatcher matcher,
    required ZCanonical canonical,
    required String sourceId,
  }) : _sources = sources,
       _matcher = matcher,
       _canonical = canonical,
       _sourceId = sourceId,
       super(const WrongTitleState());

  final SourceRepository _sources;
  final SourceMatcher _matcher;
  final ZCanonical _canonical;

  /// The title being corrected — the sheet needs it to ask the store which
  /// result is already pinned, so that one can be marked rather than offered
  /// again as if it were a different show.
  ZCanonical get canonical => _canonical;

  /// The source this correction currently applies to.
  String _sourceId;
  String get sourceId => _sourceId;

  /// Correct against a different source, re-running the same query against it.
  /// This only changes which source THIS correction searches — nothing is
  /// persisted until [choose] actually pins a result (see [pinManual]).
  /// Writing a kind-wide default just from browsing the dropdown was the bug
  /// this design fixes: every title started naming whichever source was last
  /// glanced at here.
  Future<void> setSource(String id) async {
    if (id == _sourceId) return;
    _sourceId = id;
    await search(state.query);
  }

  Future<void> search(String query) async {
    final q = query.trim();
    emit(state.copyWith(loading: true, query: q));
    try {
      final r = await _sources.search(q, sourceId: _sourceId);
      if (!isClosed) emit(state.copyWith(results: r, loading: false));
    } catch (e) {
      debugPrint('[zmode] manual search on $_sourceId failed: $e');
      if (!isClosed) emit(state.copyWith(results: const [], loading: false));
    }
  }

  Future<SourceMatch> choose(MediaItem item) =>
      _matcher.pinManual(_canonical, item);
}
