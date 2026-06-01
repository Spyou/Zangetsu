import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/home_section.dart';
import '../../../core/models/media_item.dart';
import '../../../core/repository/source_repository.dart';

/// Immutable view-state for the Home screen. The rows are CloudStream-style:
/// the active provider decides what sections exist (and what they're named),
/// so the cubit just holds whatever [SourceRepository.home] returns.
///
/// A null [sections] means "not yet loaded OR failed". The first section also
/// feeds the hero carousel via [heroItems]; the screen renders the remaining
/// sections as browse rows.
class HomeState extends Equatable {
  const HomeState({this.sections, this.loading = false});

  /// The provider's named home rows, in order. Null until the first load.
  final List<HomeSection>? sections;

  /// True while the rows are being (re)fetched.
  final bool loading;

  /// Items that drive the hero carousel — the first section's items. Empty
  /// until something loads.
  List<MediaItem> get heroItems => (sections != null && sections!.isNotEmpty)
      ? sections!.first.items
      : const [];

  HomeState copyWith({List<HomeSection>? sections, bool? loading}) => HomeState(
    sections: sections ?? this.sections,
    loading: loading ?? this.loading,
  );

  @override
  List<Object?> get props => [sections, loading];
}

/// Owns the Home rows. Delegates entirely to [SourceRepository.home], which
/// returns the active provider's own sections (or a default set for providers
/// without `getHome`). No `sourceId` is passed — `home` uses the active source
/// by design, so a source switch simply re-runs [load].
class HomeCubit extends Cubit<HomeState> {
  HomeCubit(this._repo) : super(const HomeState());

  final SourceRepository _repo;

  /// (Re)load the rows. Emits `loading: true` (keeping any existing sections so
  /// rows don't flash empty), fetches the provider's home, and emits the fresh
  /// result. A total failure yields an empty section list rather than throwing.
  Future<void> load() async {
    emit(state.copyWith(loading: true));

    List<HomeSection> sections;
    try {
      sections = await _repo.home();
    } catch (_) {
      sections = const <HomeSection>[];
    }

    if (isClosed) return;
    emit(HomeState(sections: sections, loading: false));
  }
}
