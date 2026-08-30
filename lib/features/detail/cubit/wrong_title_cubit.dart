import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/repository/source_repository.dart';
import '../../../core/zmode/match_store.dart';
import '../../../core/zmode/source_matcher.dart';
import '../../../core/zmode/zmode_ids.dart';

class WrongTitleState {
  const WrongTitleState({this.sourceId, this.results = const [], this.loading = false});

  /// Which installed source is being searched.
  final String? sourceId;
  final List<MediaItem> results;
  final bool loading;

  WrongTitleState copyWith({String? sourceId, List<MediaItem>? results, bool? loading}) =>
      WrongTitleState(
        sourceId: sourceId ?? this.sourceId,
        results: results ?? this.results,
        loading: loading ?? this.loading,
      );
}

/// Manual re-match: search one source at a time and pin the right show.
class WrongTitleCubit extends Cubit<WrongTitleState> {
  WrongTitleCubit({
    required SourceRepository sources,
    required SourceMatcher matcher,
    required ZCanonical canonical,
  }) : _sources = sources,
       _matcher = matcher,
       _canonical = canonical,
       super(WrongTitleState(sourceId: sources.loadedSources.firstOrNull?.id));

  final SourceRepository _sources;
  final SourceMatcher _matcher;
  final ZCanonical _canonical;

  List<({String id, String name})> get sources => _sources.loadedSources;

  void pickSource(String id) => emit(state.copyWith(sourceId: id, results: const []));

  Future<void> search(String query) async {
    final id = state.sourceId;
    if (id == null) return;
    emit(state.copyWith(loading: true));
    try {
      final r = await _sources.search(query.trim(), sourceId: id);
      if (!isClosed) emit(state.copyWith(results: r, loading: false));
    } catch (e) {
      debugPrint('[zmode] manual search on $id failed: $e');
      if (!isClosed) emit(state.copyWith(results: const [], loading: false));
    }
  }

  Future<SourceMatch> choose(MediaItem item) =>
      _matcher.pinManual(_canonical, item);
}
