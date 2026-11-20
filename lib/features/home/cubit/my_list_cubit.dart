import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/models/media_item.dart';
import '../../../core/models/provider_info.dart';
import '../../../core/models/watch_status.dart';
import '../../../core/playback/list_status_store.dart';
import '../../../core/playback/my_list.dart';
import '../../../core/playback/series_groups.dart';

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

/// One My List row collapsed from several grouped titles into a single card
/// (see [SeriesGroupStore]). [item] is synthesized from the group (title +
/// chosen cover); [memberItems] are the real underlying titles in group
/// order, each still openable on its own Detail screen.
class SeriesCardEntry extends MyListEntry {
  SeriesCardEntry({
    required this.group,
    required this.memberItems,
    required MediaItem displayItem,
    required WatchStatus? status,
  }) : super(displayItem, status);

  final SeriesGroup group;
  final List<MediaItem> memberItems;
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
  MyListCubit(this._store, this._status, this._series) : super(const []) {
    _store.revision.addListener(reload);
    _status.revision.addListener(reload);
    _series.revision.addListener(reload);
    reload();
  }

  final MyListStore _store;
  final ListStatusStore _status;
  final SeriesGroupStore _series;

  void reload() {
    if (isClosed) return;
    final flat = [
      for (final m in _store.all()) MyListEntry(m, _status.statusOf(m)),
    ];
    final next = _collapseGroups(flat);
    if (_unchanged(state, next)) return;
    emit(next);
  }

  /// Replaces every grouped entry's run with one [SeriesCardEntry], keeping
  /// ungrouped entries exactly where they were. Each group appears once, at
  /// the position of its first member in [flat].
  List<MyListEntry> _collapseGroups(List<MyListEntry> flat) {
    final groups = _series.all();
    if (groups.isEmpty) return flat;
    final byKey = {for (final e in flat) '${e.item.sourceId}::${e.item.id}': e};
    final consumed = <String>{};
    final out = <MyListEntry>[];
    for (final e in flat) {
      final key = '${e.item.sourceId}::${e.item.id}';
      if (consumed.contains(key)) continue;
      final group = _series.groupOf(key);
      if (group == null) {
        out.add(e);
        continue;
      }
      final memberEntries = [
        for (final k in group.memberKeys)
          if (byKey[k] != null) byKey[k]!,
      ];
      if (memberEntries.isEmpty) continue;
      consumed.addAll(group.memberKeys);
      final cover = switch (group.coverMode) {
        SeriesCoverMode.entry =>
          byKey[group.coverMemberKey]?.item ?? memberEntries.first.item,
        SeriesCoverMode.custom => memberEntries.first.item,
        SeriesCoverMode.auto => memberEntries.first.item,
      };
      final latest = memberEntries.reduce(
        (a, b) =>
            (b.updatedAt ??
                    DateTime.fromMillisecondsSinceEpoch(b.item.savedAtMs ?? 0))
                .isAfter(
                  a.updatedAt ??
                      DateTime.fromMillisecondsSinceEpoch(
                        a.item.savedAtMs ?? 0,
                      ),
                )
            ? b
            : a,
      );
      out.add(
        SeriesCardEntry(
          group: group,
          memberItems: [for (final m in memberEntries) m.item],
          displayItem: cover.copyWith(title: group.title),
          status: latest.status,
        ),
      );
    }
    return out;
  }

  static bool _unchanged(List<MyListEntry> a, List<MyListEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (x is SeriesCardEntry != y is SeriesCardEntry) return false;
      if (x is SeriesCardEntry && y is SeriesCardEntry) {
        final xKeys = x.group.memberKeys, yKeys = y.group.memberKeys;
        if (x.group.id != y.group.id ||
            x.group.title != y.group.title ||
            x.group.coverMode != y.group.coverMode ||
            x.group.coverMemberKey != y.group.coverMemberKey ||
            x.memberItems.length != y.memberItems.length ||
            xKeys.length != yKeys.length) {
          return false;
        }
        for (var j = 0; j < xKeys.length; j++) {
          if (xKeys[j] != yKeys[j]) return false;
        }
      }
      if (x.item.url != y.item.url ||
          x.item.savedAtMs != y.item.savedAtMs ||
          x.status != y.status) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<void> close() {
    _store.revision.removeListener(reload);
    _status.revision.removeListener(reload);
    _series.revision.removeListener(reload);
    return super.close();
  }
}
