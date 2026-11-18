import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/models/provider_info.dart';
import '../../../core/models/watch_status.dart';
import '../../../core/playback/list_status_store.dart';
import '../../../core/playback/my_list.dart';

/// One My List row: the title plus its library status (null = saved without a
/// status, e.g. a legacy bookmark).
class MyListEntry {
  const MyListEntry(
    this.item,
    this.status, {
    this.progress,
    this.score,
    this.tmdbIsTv = false,
    this.updatedAt,
    this.customLists = const [],
    this.isPrivate = false,
    this.totalEpisodes,
    this.nextAiringEpisode,
    this.isUnreleased = false,
  });
  final MediaItem item;
  final WatchStatus? status;

  /// Episodes watched / user score — populated only for tracker lists (AniList /
  /// MAL / Simkl), which read these back per entry. Always null for the own list.
  final int? progress;
  final double? score;

  /// Released/total counts for the behind badge — populated only for tracker
  /// lists (AniList reports both, MAL/Simkl report totals). Null on the own
  /// list, which carries no watched counts either — those cards never chip.
  final int? totalEpisodes;
  final int? nextAiringEpisode;

  /// The catalogue hasn't released this title yet — the card says "Soon"
  /// instead of nothing. Only set when a tracker actually reports it.
  final bool isUnreleased;

  /// When the tracker last changed this entry — drives the "Last updated"
  /// sort. Null for the own list, which keeps no such timestamp.
  final DateTime? updatedAt;

  /// AniList's OWN custom lists this entry is in. Empty everywhere else —
  /// MAL and Simkl have no such concept. Not the app's local categories.
  final List<String> customLists;
  final bool isPrivate;

  /// Simkl movies/TV are resolved by TMDB id; this marks TV shows so an edit
  /// writes to the right Simkl bucket. False for anime and the own list.
  final bool tmdbIsTv;
}

/// Released episode count for the behind chip: one behind the next airing
/// episode while a show airs, the total once it's done. Null when unknown.
int? _releasedOf(MyListEntry e) {
  final released = e.nextAiringEpisode != null
      ? e.nextAiringEpisode! - 1
      : e.totalEpisodes;
  return (released == null || released <= 0) ? null : released;
}

/// Released-but-unwatched episode count for the behind chip. Null when
/// unknown or caught up (no chip), and never for one-shot movies.
/// ponytail: pure arithmetic, no/store lookups per card.
int? behindCount(MyListEntry e) {
  if (e.item.type == ProviderType.movie && !e.tmdbIsTv) return null;
  final released = _releasedOf(e);
  if (released == null) return null;
  final behind = released - (e.progress ?? 0);
  return behind > 0 ? behind : null;
}

/// Chip text: "0/12" never started, "3/12" behind, "10/10" caught up,
/// [soonText] when the title isn't out yet. Null when unknown. Production
/// passes the localized string; the default is test-only English.
/// ponytail: same inputs as [behindCount].
String? behindLabel(MyListEntry e, [String soonText = 'Soon']) {
  if (e.item.type == ProviderType.movie && !e.tmdbIsTv) return null;
  final released = _releasedOf(e);
  if (released == null) return e.isUnreleased ? soonText : null;
  final watched = e.progress ?? 0;
  if (watched <= 0) return '0/$released';
  final behind = released - watched;
  return behind > 0 ? '$behind/$released' : '$released/$released';
}

/// Owns My List — the user's OWN saved titles ([MyListStore]), each annotated
/// with its [WatchStatus] from [ListStatusStore]. This is the app's personal
/// list; AniList's own lists are NOT merged in. Re-emits when either source
/// changes.
class MyListCubit extends Cubit<List<MyListEntry>> {
  MyListCubit(this._store, this._status) : super(const []) {
    _store.revision.addListener(reload);
    _status.revision.addListener(reload);
    reload();
  }

  final MyListStore _store;
  final ListStatusStore _status;

  void reload() {
    if (isClosed) return;
    final next = [
      for (final m in _store.all()) MyListEntry(m, _status.statusOf(m)),
    ];
    // The stores fire a revision even when the resulting list is identical
    // (e.g. an unrelated status write elsewhere). Skip the emit — and the whole
    // grid rebuild — when nothing actually changed.
    if (_unchanged(state, next)) return;
    emit(next);
  }

  static bool _unchanged(List<MyListEntry> a, List<MyListEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].item.url != b[i].item.url ||
          a[i].item.savedAtMs != b[i].item.savedAtMs ||
          a[i].status != b[i].status) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<void> close() {
    _store.revision.removeListener(reload);
    _status.revision.removeListener(reload);
    return super.close();
  }
}
