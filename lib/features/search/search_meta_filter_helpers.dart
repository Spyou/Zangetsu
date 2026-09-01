import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/playback/search_scope.dart';
import '../../core/ui/app_toast.dart';
import '../../core/zmode/metadata_filters.dart';
import '../../core/zmode/metadata_repository.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';
import 'bloc/search_bloc.dart';
import 'bloc/search_event.dart';
import 'meta_filter_sheet.dart';

/// Hint text for the search field — scope- and mode-aware.
String searchHintForScope(BuildContext context, SearchScope scope) {
  if (scope == SearchScope.sources) return context.l10n.search2;
  if (!sl.isRegistered<ContentModeCubit>()) {
    return context.l10n.searchAnime;
  }
  return switch (browseKindFor(
    sl<ContentModeCubit>().state,
    ZModePrefs.streamKind,
  )) {
    ZKind.anime => context.l10n.searchAnime,
    ZKind.movie || ZKind.tv => context.l10n.searchMoviesTv,
    ZKind.manga => context.l10n.searchManga,
    ZKind.novel => context.l10n.searchNovels,
  };
}

/// How many metadata filters are non-default (for badge counts).
int metaFilterActiveCount(MetaFilters filters) {
  return (filters.genres.isNotEmpty ? 1 : 0) +
      (filters.year != null ? 1 : 0) +
      (filters.season != null ? 1 : 0) +
      (filters.format != null ? 1 : 0) +
      (filters.status != null ? 1 : 0) +
      (filters.minScore != null ? 1 : 0) +
      (filters.sort != MetaSort.popularity ? 1 : 0);
}

/// Push metadata filters into [SearchBloc] and re-run/browse.
void applyMetaFilters(BuildContext context, MetaFilters filters) {
  context.read<SearchBloc>().add(
    SearchSourceFiltersApplied(
      ZmodeIds.sourceId,
      filters.isEmpty ? '' : filters.toJson(),
    ),
  );
}

/// Open the metadata catalogue filter picker. [useDialog] for TV D-pad layouts.
Future<MetaFilters?> pickMetaFilters(
  BuildContext context,
  MetaFilters current, {
  bool useDialog = false,
}) async {
  if (!sl.isRegistered<ContentModeCubit>()) return null;
  final kind = browseKindFor(
    sl<ContentModeCubit>().state,
    ZModePrefs.streamKind,
  );
  if (!sl<MetadataRepository>().supportsFilters) {
    final needed =
        (kind == ZKind.movie || kind == ZKind.tv) ? 'TMDB' : 'AniList';
    showAppToast(context, context.l10n.filtersNeedProvider(needed));
    return null;
  }
  FocusScope.of(context).unfocus();
  if (useDialog) {
    return showMetaFilterDialog(context, kind, current);
  }
  return showMetaFilterSheet(context, kind, current);
}
