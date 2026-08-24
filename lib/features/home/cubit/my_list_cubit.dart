import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/models/watch_status.dart';
import '../../../core/playback/list_status_store.dart';
import '../../../core/playback/my_list.dart';

/// One My List row: the title plus its library status (null = saved without a
/// status, e.g. a legacy bookmark).
class MyListEntry {
  const MyListEntry(this.item, this.status,
      {this.progress,
      this.score,
      this.tmdbIsTv = false,
      this.updatedAt,
      this.customLists = const []});
  final MediaItem item;
  final WatchStatus? status;

  /// Episodes watched / user score — populated only for tracker lists (AniList /
  /// MAL / Simkl), which read these back per entry. Always null for the own list.
  final int? progress;
  final double? score;

  /// When the tracker last changed this entry — drives the "Last updated"
  /// sort. Null for the own list, which keeps no such timestamp.
  final DateTime? updatedAt;

  /// AniList's OWN custom lists this entry is in. Empty everywhere else —
  /// MAL and Simkl have no such concept. Not the app's local categories.
  final List<String> customLists;

  /// Simkl movies/TV are resolved by TMDB id; this marks TV shows so an edit
  /// writes to the right Simkl bucket. False for anime and the own list.
  final bool tmdbIsTv;
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
      if (a[i].item.url != b[i].item.url || a[i].status != b[i].status) {
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
