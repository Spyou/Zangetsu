import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/repository/source_repository.dart';
import '../../../core/zmode/match_store.dart';
import '../../../core/zmode/source_matcher.dart';
import '../../../core/zmode/zmode_ids.dart';

class WrongTitleState {
  const WrongTitleState({this.results = const [], this.loading = false});

  final List<MediaItem> results;
  final bool loading;

  WrongTitleState copyWith({List<MediaItem>? results, bool? loading}) =>
      WrongTitleState(
        results: results ?? this.results,
        loading: loading ?? this.loading,
      );
}

/// Manual re-match against ONE source (the one already selected on the
/// Detail screen): search it and pin the right result.
class WrongTitleCubit extends Cubit<WrongTitleState> {
  WrongTitleCubit({
    required SourceRepository sources,
    required SourceMatcher matcher,
    required ZCanonical canonical,
    required this.sourceId,
  }) : _sources = sources,
       _matcher = matcher,
       _canonical = canonical,
       super(const WrongTitleState());

  final SourceRepository _sources;
  final SourceMatcher _matcher;
  final ZCanonical _canonical;

  /// The one source this correction applies to.
  final String sourceId;

  Future<void> search(String query) async {
    emit(state.copyWith(loading: true));
    try {
      final r = await _sources.search(query.trim(), sourceId: sourceId);
      if (!isClosed) emit(state.copyWith(results: r, loading: false));
    } catch (e) {
      debugPrint('[zmode] manual search on $sourceId failed: $e');
      if (!isClosed) emit(state.copyWith(results: const [], loading: false));
    }
  }

  Future<SourceMatch> choose(MediaItem item) =>
      _matcher.pinManual(_canonical, item);
}
