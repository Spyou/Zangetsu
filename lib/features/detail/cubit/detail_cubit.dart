import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injector.dart';
import '../../../core/models/episode.dart';
import '../../../core/models/media_detail.dart';
import '../../../core/models/provider_info.dart';
import '../../../core/playback/title_prefs.dart';
import '../../../core/repository/source_repository.dart';

/// Lifecycle of the detail load. Mirrors Sozo Read's `DetailStatus`
/// (we drop `initial` — the cubit starts in `loading` since `load()`
/// fires immediately on construction).
enum DetailStatus { loading, success, error }

/// Immutable view-state for the Detail screen. Owns everything that used
/// to live in `_DetailScreenState`'s setState fields: the fetched
/// [MediaDetail], the sub/dub [category], the selected season, and the
/// description-expanded flag. The scroll-driven app-bar title fade is
/// pure UI state and intentionally stays widget-level.
class DetailState extends Equatable {
  const DetailState({
    this.status = DetailStatus.loading,
    this.detail,
    this.category = 'sub',
    this.selectedSeason = 1,
    this.descExpanded = false,
    this.error,
  });

  final DetailStatus status;
  final MediaDetail? detail;

  /// 'sub' | 'dub'. Drives the Sub/Dub toggle and the player `category`.
  final String category;
  final int selectedSeason;
  final bool descExpanded;
  final String? error;

  DetailState copyWith({
    DetailStatus? status,
    MediaDetail? detail,
    String? category,
    int? selectedSeason,
    bool? descExpanded,
    String? error,
  }) => DetailState(
    status: status ?? this.status,
    detail: detail ?? this.detail,
    category: category ?? this.category,
    selectedSeason: selectedSeason ?? this.selectedSeason,
    descExpanded: descExpanded ?? this.descExpanded,
    error: error ?? this.error,
  );

  @override
  List<Object?> get props => [
    status,
    detail,
    category,
    selectedSeason,
    descExpanded,
    error,
  ];
}

class DetailCubit extends Cubit<DetailState> {
  DetailCubit({
    required SourceRepository repo,
    required String url,
    String? sourceId,
    TitlePrefsStore? prefs,
  }) : _repo = repo,
       _url = url,
       _sourceId = sourceId,
       _prefs = prefs ?? sl<TitlePrefsStore>(),
       // Seed the INITIAL category from the per-title remembered choice so the
       // Sub/Dub toggle reflects the saved value on the very first render (no
       // flash from 'sub' → remembered). Falls back to 'sub' when unset.
       super(
         DetailState(
           category:
               (prefs ?? sl<TitlePrefsStore>()).category(sourceId ?? '', url) ??
               'sub',
         ),
       );

  final SourceRepository _repo;
  final String _url;
  final TitlePrefsStore _prefs;

  /// The owning item's source. When null, repo calls fall back to the
  /// active source. Set from `DetailScreen(item:).sourceId` so a title
  /// opened from My List / cross-source rows queries its OWN provider.
  final String? _sourceId;

  /// Stable key component for per-title prefs. Falls back to '' when the
  /// owning source is unknown (active-source title) — robust, never throws.
  String get _prefsSourceId => _sourceId ?? '';

  /// Initial fetch. Emits loading then success/error for the current
  /// [DetailState.category] (the per-title remembered choice, else 'sub').
  Future<void> load() async {
    emit(state.copyWith(status: DetailStatus.loading));
    try {
      final detail = await _repo.detail(
        _url,
        category: state.category,
        sourceId: _sourceId,
      );
      emit(state.copyWith(status: DetailStatus.success, detail: detail));
    } catch (_) {
      emit(state.copyWith(status: DetailStatus.error, error: 'load_failed'));
    }
  }

  /// Sub/Dub re-fetch. No-op when the category is unchanged. Otherwise
  /// flips to loading for the new category and re-fetches, resetting the
  /// selected season to 1 (the new audio track may have a different set
  /// of seasons). Matches the original `onAudioChanged` behavior.
  Future<void> setCategory(String cat) async {
    if (cat == state.category) return;
    emit(state.copyWith(category: cat, status: DetailStatus.loading));
    try {
      final detail = await _repo.detail(
        _url,
        category: cat,
        sourceId: _sourceId,
      );
      emit(
        state.copyWith(
          status: DetailStatus.success,
          detail: detail,
          selectedSeason: 1,
        ),
      );
      // Netflix-style: remember THIS title's Sub/Dub choice so reopening it
      // restores the last-picked category. Only after a successful switch.
      await _prefs.setCategory(_prefsSourceId, _url, cat);
    } catch (_) {
      emit(state.copyWith(status: DetailStatus.error, error: 'load_failed'));
    }
  }

  void selectSeason(int s) {
    if (s == state.selectedSeason) return;
    emit(state.copyWith(selectedSeason: s));
  }

  void toggleDesc() => emit(state.copyWith(descExpanded: !state.descExpanded));
}

// ─────────────────────────────────────────────────────────────────────────────
// Pure helpers — moved off the screen state. Stateless, so they live as
// top-level functions for both the cubit and the view to share.
// ─────────────────────────────────────────────────────────────────────────────

String statusLabel(MediaStatus status) {
  switch (status) {
    case MediaStatus.ongoing:
      return 'Ongoing';
    case MediaStatus.completed:
      return 'Completed';
    case MediaStatus.hiatus:
      return 'Hiatus';
    case MediaStatus.cancelled:
      return 'Cancelled';
    case MediaStatus.unknown:
      return '';
  }
}

/// Parse the season number from the start of an episode title.
/// Returns null if no such prefix exists.
/// E.g. "S1 E3 - Attack" gives 1; "Episode 5" gives null.
int? parseSeason(String title) {
  final m = RegExp(r'^S(\d+)').firstMatch(title.trim());
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// Derive the set of seasons present in the episode list.
/// Returns an empty set when no episode has a season prefix (single-season).
Set<int> seasonsOf(List<Episode> eps) {
  final result = <int>{};
  for (final ep in eps) {
    final s = parseSeason(ep.title);
    if (s != null) result.add(s);
  }
  return result;
}

/// Strip a leading season+episode prefix from a title so the episode
/// row shows a clean title without redundant numbering.
String cleanTitle(String title) {
  return title.replaceFirst(RegExp(r'^S\d+\s+E\d+\s*[-–—]?\s*'), '').trim();
}

/// Whether to show the Sub/Dub toggle:
/// - Only for anime (ProviderType.anime)
/// - And at least one of subCount / dubCount is non-zero / non-null
bool showSubDubFor(MediaDetail detail) {
  if (detail.type != ProviderType.anime) return false;
  final hasSub = (detail.subCount ?? 0) > 0;
  final hasDub = (detail.dubCount ?? 0) > 0;
  return hasSub || hasDub;
}
