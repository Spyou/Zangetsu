import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// Which sources are turned OFF for search. Default: none — every source is
/// searched. This is SEARCH-ONLY and independent of the global enable/disable,
/// so switching a source off here only hides it from search results; it stays
/// usable as the Home/active source. Backed by a tiny Hive box.
///
/// A [ChangeNotifier] so the picker sheet rebuilds live as toggles flip.
class SearchSourcePrefs extends ChangeNotifier {
  static const String boxName = 'search_prefs';
  static const String _excludedKey = 'excludedSources';

  /// Opens the box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  /// The source ids excluded from search.
  Set<String> get excluded {
    final raw = _box.get(_excludedKey);
    if (raw is List) return {for (final e in raw) '$e'};
    return <String>{};
  }

  /// True when [id] participates in search (the default for any unknown id).
  bool isIncluded(String id) => !excluded.contains(id);

  /// Turn one source on/off for search.
  Future<void> setIncluded(String id, bool included) async {
    final set = excluded;
    if (included ? set.remove(id) : set.add(id)) {
      await _box.put(_excludedKey, set.toList());
      notifyListeners();
    }
  }

  /// Turn many sources on/off for search at once (per-category select all/none).
  Future<void> setManyIncluded(Iterable<String> ids, bool included) async {
    final set = excluded;
    var changed = false;
    for (final id in ids) {
      changed = (included ? set.remove(id) : set.add(id)) || changed;
    }
    if (changed) {
      await _box.put(_excludedKey, set.toList());
      notifyListeners();
    }
  }
}
