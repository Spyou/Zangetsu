import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/repository/source_repository.dart';

/// Immutable view-state for the Home screen's three browse rows + the hero
/// carousel's trending source. Owns the network futures that used to live in
/// `_HomeScreenState`'s cached-future fields.
///
/// A null list means "not yet loaded OR failed" — the row is omitted. The
/// [loading] flag drives the `RowSkeleton` placeholders during the in-flight
/// fetch (true while the first load is in progress).
class HomeState extends Equatable {
  const HomeState({
    this.trending,
    this.month,
    this.allTime,
    this.loading = false,
  });

  /// Trending Now (dateRange: 1). Also feeds the hero [FeaturedCarousel].
  final List<MediaItem>? trending;

  /// Popular This Month (dateRange: 30).
  final List<MediaItem>? month;

  /// All-Time Favorites (dateRange: 0).
  final List<MediaItem>? allTime;

  /// True while the three rows are being (re)fetched.
  final bool loading;

  HomeState copyWith({
    List<MediaItem>? trending,
    List<MediaItem>? month,
    List<MediaItem>? allTime,
    bool? loading,
  }) =>
      HomeState(
        trending: trending ?? this.trending,
        month: month ?? this.month,
        allTime: allTime ?? this.allTime,
        loading: loading ?? this.loading,
      );

  @override
  List<Object?> get props => [trending, month, allTime, loading];
}

/// Owns the three Home browse rows. Fetches `repo.popular(dateRange: 1/30/0)`
/// in parallel; each fetch is fail-safe (a failure yields an empty list so one
/// broken row never kills the others). No `sourceId` is passed — `popular`
/// uses the active source by design, so a source switch simply re-runs
/// [load].
class HomeCubit extends Cubit<HomeState> {
  HomeCubit(this._repo) : super(const HomeState());

  final SourceRepository _repo;

  /// (Re)load the three rows. Emits `loading: true` (keeping any existing
  /// lists so rows don't flash empty), then fetches all three in parallel —
  /// each `.catchError` to an empty list so a single failure is isolated —
  /// and emits the fresh result with `loading: false`.
  Future<void> load() async {
    emit(state.copyWith(loading: true));

    final results = await Future.wait([
      _repo.popular(dateRange: 1).catchError((_) => <MediaItem>[]),
      _repo.popular(dateRange: 30).catchError((_) => <MediaItem>[]),
      _repo.popular(dateRange: 0).catchError((_) => <MediaItem>[]),
    ]);

    if (isClosed) return;
    emit(HomeState(
      trending: results[0],
      month: results[1],
      allTime: results[2],
      loading: false,
    ));
  }
}
