import '../../core/models/watch_status.dart';
import 'cubit/my_list_cubit.dart';

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
