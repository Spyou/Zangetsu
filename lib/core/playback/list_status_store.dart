import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/media_item.dart';
import '../models/watch_status.dart';

/// Local, device-side status for every title in My List, keyed by
/// `sourceId::id`. Deliberately a SEPARATE box from [MyListStore] (which clears
/// + repopulates on Appwrite login) so a cloud pull never wipes statuses. For
/// anime the authoritative copy lives on AniList; this is the local mirror that
/// also covers movies and offline use.
class ListStatusStore {
  static const String boxName = 'list_status';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await Hive.openBox(boxName);
  }

  Box get _box => Hive.box(boxName);

  /// Bumped on every change so My List can rebuild.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  String keyOf(MediaItem m) => '${m.sourceId}::${m.id}';

  WatchStatus? statusOf(MediaItem m) =>
      watchStatusFromName(_box.get(keyOf(m)) as String?);

  WatchStatus? statusOfKey(String key) =>
      watchStatusFromName(_box.get(key) as String?);

  Future<void> setStatus(MediaItem m, WatchStatus status) async {
    await _box.put(keyOf(m), status.name);
    revision.value++;
  }

  Future<void> setStatusKey(String key, WatchStatus status) async {
    await _box.put(key, status.name);
    revision.value++;
  }

  Future<void> remove(MediaItem m) async {
    await _box.delete(keyOf(m));
    revision.value++;
  }

  /// Hydrate the local mirror from a persisted status name (used when a cloud
  /// pull carries a status). Does NOT bump [revision] — the pull triggers a
  /// single My List refresh once it finishes, so per-item bumps would just
  /// churn. A null name clears the entry.
  Future<void> setStatusRaw(String key, String? name) async {
    if (name == null) {
      await _box.delete(key);
    } else {
      await _box.put(key, name);
    }
  }
}
