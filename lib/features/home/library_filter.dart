import 'dart:math';

import '../../core/models/watch_status.dart';
import '../../core/mode/content_mode.dart';
import '../../core/playback/category_store.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import 'cubit/my_list_cubit.dart';

List<ContentMode> libraryKindsForTracker(Tracker? tracker) => [
  for (final mode in ContentMode.values)
    if (tracker == null ||
        (mode.isReading
            ? tracker.supportsReading
            : trackerSupportsVideo(tracker)))
      mode,
];

ContentMode libraryKindForTracker(Tracker? tracker, ContentMode preferred) {
  final kinds = libraryKindsForTracker(tracker);
  return kinds.contains(preferred) ? preferred : kinds.first;
}

/// Picks one entry from the already-filtered library view, or null when it is
/// empty. The optional [random] keeps the choice deterministic in tests.
T? pickRandomLibraryEntry<T>(List<T> entries, {Random? random}) {
  if (entries.isEmpty) return null;
  return entries[(random ?? Random()).nextInt(entries.length)];
}

/// Fixed tab order matching the phone My List screen.
const libraryStatusTabOrder = [
  WatchStatus.watching,
  WatchStatus.planning,
  WatchStatus.completed,
  WatchStatus.paused,
  WatchStatus.dropped,
];

/// Statuses that actually have at least one entry, in [libraryStatusTabOrder].
List<WatchStatus> presentLibraryStatuses(List<MyListEntry> entries) =>
    libraryStatusTabOrder
        .where((s) => entries.any((e) => e.status == s))
        .toList();

/// Filter a library list the same way the phone tabs do.
List<MyListEntry> filterLibraryEntries(
  List<MyListEntry> entries, {
  WatchStatus? status,
  String? customList,
  bool Function(MyListEntry)? inCategory,
}) {
  return [
    for (final e in entries)
      if ((status == null || e.status == status) &&
          (customList == null || e.customLists.contains(customList)) &&
          (inCategory == null || inCategory(e)))
        e,
  ];
}

/// Reuses category counts across layout changes without retaining another
/// profile's assignments or stale list/category data.
class LibraryCategoryCounts {
  LibraryCategoryCounts(this.store);

  final CategoryStore store;
  String? _profile;
  int? _revision;
  List<MyListEntry>? _entries;
  final _byKind = <ContentMode, Map<String, int>>{};
  final _totals = <String, int>{};

  void _syncScope() {
    final profile = store.profileId;
    final revision = store.revision.value;
    if (profile == _profile && revision == _revision) return;
    _profile = profile;
    _revision = revision;
    _byKind.clear();
    _totals.clear();
  }

  Map<String, int> forEntries(List<MyListEntry> entries, ContentMode kind) {
    _syncScope();
    if (!identical(entries, _entries)) {
      _entries = entries;
      _byKind.clear();
    }
    return _byKind.putIfAbsent(kind, () {
      final counts = <String, int>{};
      for (final entry in entries) {
        if (!kind.matchesProvider(entry.item.type)) continue;
        for (final id in store.categoriesOf(entry.item)) {
          counts.update(id, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      return Map.unmodifiable(counts);
    });
  }

  int total(String categoryId) {
    _syncScope();
    return _totals.putIfAbsent(categoryId, () => store.countIn(categoryId));
  }
}
