import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../core/mode/content_mode.dart';

/// Home-only catalogue choice. It does not change the app's active source or
/// the source used for playback and downloads.
///
/// The picked source is remembered SEPARATELY PER MODE: anime and manga have
/// disjoint source lists, so one shared slot meant every mode switch resolved
/// a fallback (active-or-first) and persisted it over the user's real pick —
/// flipping to manga and back silently forgot the anime source. `sourceIdFor`
/// / `setSourceIdFor` key the slot by mode; the old single key is kept purely
/// as a one-time migration read for installs that predate the split.
class HomeCataloguePrefs {
  HomeCataloguePrefs._();

  static const boxName = 'app_prefs';
  static const _modeKey = 'homeCatalogueMode';
  static const _sourceIdKey = 'homeCatalogueSourceId';
  static ValueNotifier<bool>? _sourceSelection;

  static bool get sourceSelected =>
      Hive.isBoxOpen(boxName) && Hive.box(boxName).get(_modeKey) == 'source';

  static ValueNotifier<bool> get sourceSelection {
    final selected = sourceSelected;
    final notifier = _sourceSelection ??= ValueNotifier(selected);
    if (notifier.value != selected) notifier.value = selected;
    return notifier;
  }

  static String _keyFor(ContentMode mode) => '$_sourceIdKey.${mode.name}';

  /// The saved source for [mode], falling back to the pre-split single slot
  /// once (then the next write for [mode] takes over permanently).
  static String? sourceIdFor(ContentMode mode) {
    if (!Hive.isBoxOpen(boxName)) return null;
    final box = Hive.box(boxName);
    final id = box.get(_keyFor(mode));
    if (id is String && id.isNotEmpty) return id;
    return sourceId;
  }

  /// Legacy single slot: pre-split installs only. New code uses [sourceIdFor].
  static String? get sourceId {
    if (!Hive.isBoxOpen(boxName)) return null;
    final id = Hive.box(boxName).get(_sourceIdKey);
    return id is String && id.isNotEmpty ? id : null;
  }

  static Future<void> setSourceSelected(bool selected) async {
    if (!Hive.isBoxOpen(boxName)) return;
    await Hive.box(boxName).put(_modeKey, selected ? 'source' : 'metadata');
    _sourceSelection?.value = selected;
  }

  static Future<void> setSourceIdFor(ContentMode mode, String id) async {
    if (!Hive.isBoxOpen(boxName) || id.isEmpty) return;
    final box = Hive.box(boxName);
    await box.put(_keyFor(mode), id);
    // The split supersedes the shared slot; drop it so a stale value can
    // never shadow a per-mode pick again.
    await box.delete(_sourceIdKey);
  }

  /// Legacy single-slot write (pre-split installs). Prefer [setSourceIdFor].
  static Future<void> setSourceId(String id) async {
    if (!Hive.isBoxOpen(boxName) || id.isEmpty) return;
    await Hive.box(boxName).put(_sourceIdKey, id);
  }
}
