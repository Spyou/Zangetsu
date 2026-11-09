import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../../core/mode/content_mode.dart';

/// What Home is showing: a metadata catalogue, an installed source, or the
/// Stremio addon catalogue.
enum HomeCatalogueKind { metadata, source, stremio }

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

  /// Bumped on every catalogue write. Unlike [sourceSelection] (source vs
  /// metadata only) this also fires when Source ↔ Stremio changes, so Home
  /// reloads the rows it should actually be showing.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String _savedKind() {
    if (!Hive.isBoxOpen(boxName)) return 'metadata';
    final value = Hive.box(boxName).get(_modeKey);
    return value is String && value.isNotEmpty ? value : 'metadata';
  }

  static HomeCatalogueKind get catalogueKind {
    switch (_savedKind()) {
      case 'source':
        return HomeCatalogueKind.source;
      case 'stremio':
        return HomeCatalogueKind.stremio;
      default:
        return HomeCatalogueKind.metadata;
    }
  }

  /// True when Home shows a installed-source catalogue (the pre-Stremio
  /// behaviour). Stremio has its own value and must not be mistaken for it.
  static bool get sourceSelected => catalogueKind == HomeCatalogueKind.source;

  static bool get stremioSelected => catalogueKind == HomeCatalogueKind.stremio;

  /// True for any non-metadata Home (source catalogue or Stremio).
  static bool get catalogueShown => catalogueKind != HomeCatalogueKind.metadata;

  static ValueNotifier<bool> get sourceSelection {
    final selected = sourceSelected;
    final notifier = _sourceSelection ??= ValueNotifier(selected);
    if (notifier.value != selected) notifier.value = selected;
    return notifier;
  }

  static String _keyFor(ContentMode mode) => '$_sourceIdKey.${mode.name}';

  /// The saved source for [mode], falling back to the pre-split single slot
  /// once (then the next write for [mode] takes over permanently).
  ///
  /// While Stremio is the Home catalogue, video modes show Stremio. Reading
  /// modes keep their own source choice — Stremio is a watching catalogue.
  static String? sourceIdFor(ContentMode mode) {
    if (!Hive.isBoxOpen(boxName)) return null;
    final box = Hive.box(boxName);
    if (stremioSelected && mode == ContentMode.anime) return 'stremio';
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

  static Future<void> setCatalogue(
    ContentMode mode,
    HomeCatalogueKind kind,
  ) async {
    if (!Hive.isBoxOpen(boxName)) return;
    await Hive.box(boxName).put(_modeKey, kind.name);
    _changed();
  }

  static Future<void> setSourceSelected(bool selected) async {
    if (!Hive.isBoxOpen(boxName)) return;
    await Hive.box(boxName).put(_modeKey, selected ? 'source' : 'metadata');
    _changed();
  }

  static Future<void> setSourceIdFor(ContentMode mode, String id) async {
    if (!Hive.isBoxOpen(boxName) || id.isEmpty) return;
    if (id == 'stremio') {
      await Hive.box(boxName).put(_modeKey, 'stremio');
      _changed();
      return;
    }
    await _putSourceId(mode, id);
    if (stremioSelected) {
      await Hive.box(boxName).put(_modeKey, 'source');
    }
    _changed();
  }

  /// Legacy single-slot write (pre-split installs). Prefer [setSourceIdFor].
  static Future<void> setSourceId(String id) async {
    if (!Hive.isBoxOpen(boxName) || id.isEmpty) return;
    await Hive.box(boxName).put(_sourceIdKey, id);
  }

  static Future<void> _putSourceId(ContentMode mode, String id) async {
    final box = Hive.box(boxName);
    await box.put(_keyFor(mode), id);
    // The split supersedes the shared slot; drop it so a stale value can
    // never shadow a per-mode pick again.
    await box.delete(_sourceIdKey);
  }

  static void _changed() {
    _sourceSelection?.value = sourceSelected;
    revision.value++;
  }
}
