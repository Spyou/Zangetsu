import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/home_section.dart';
import '../../../core/repository/catalogue_repository.dart';

class BrowseSourceState {
  const BrowseSourceState({
    this.sections = const [],
    this.loading = true,
    this.failed = false,
  });

  final List<HomeSection> sections;
  final bool loading;

  /// The source threw. Distinct from "returned nothing" — an empty catalogue
  /// is a legitimate answer and must not be dressed up as a failure.
  final bool failed;
}

/// One source's own catalogue. Deliberately holds a [CatalogueRepository] and
/// is constructed with `SourceRepository`, never the Z Mode router: this screen
/// browses a real source by definition.
class BrowseSourceCubit extends Cubit<BrowseSourceState> {
  BrowseSourceCubit({required CatalogueRepository repo, required this.sourceId})
      : _repo = repo,
        super(const BrowseSourceState());

  final CatalogueRepository _repo;
  final String sourceId;

  Future<void> load() async {
    emit(const BrowseSourceState());
    try {
      final sections = await _repo.home(sourceId: sourceId);
      if (isClosed) return;
      emit(BrowseSourceState(sections: sections, loading: false));
    } catch (_) {
      if (isClosed) return;
      emit(const BrowseSourceState(loading: false, failed: true));
    }
  }
}
