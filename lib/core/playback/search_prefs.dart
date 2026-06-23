import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// How cross-source search results are laid out.
///
/// - [vertical]: each source's results in a grid under its header.
/// - [horizontal]: each source's results in a CloudStream-style scrolling row.
enum SearchLayout {
  vertical('Vertical (grid)'),
  horizontal('Horizontal (rows)');

  const SearchLayout(this.label);
  final String label;
}

/// Persisted search preferences that outlive a single screen open: the results
/// LAYOUT (grid vs rows) plus the last-used FILTERS (content type, genre,
/// decade) and SORT. Source toggles stay in [SearchSourcePrefs]; this store
/// covers everything else the search screen needs to remember.
///
/// Backed by a tiny Hive box (same pattern as [SearchSourcePrefs]). A
/// [ChangeNotifier] so the layout toggle in Settings rebuilds live.
class SearchPrefs extends ChangeNotifier {
  static const String boxName = 'search_view_prefs';
  static const String _layoutKey = 'layout';
  static const String _contentFilterKey = 'contentFilter';
  static const String _sortKey = 'sort';
  static const String _genreKey = 'genre';
  static const String _decadeKey = 'decade';
  static const String _currentSourceOnlyKey = 'currentSourceOnly';

  /// Opens the box. Call once during app bootstrap before constructing.
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  // ── Layout (the one Settings exposes) ─────────────────────────────────────
  /// Default is [SearchLayout.vertical] — the grid most users expect and the
  /// densest way to scan many results.
  SearchLayout get layout {
    final raw = _box.get(_layoutKey);
    return SearchLayout.values.firstWhere(
      (l) => l.name == raw,
      orElse: () => SearchLayout.vertical,
    );
  }

  Future<void> setLayout(SearchLayout layout) async {
    if (layout == this.layout) return;
    await _box.put(_layoutKey, layout.name);
    notifyListeners();
  }

  // ── Search scope (CloudStream-style "current source only") ────────────────
  /// When true, search queries ONLY the currently-active Home source instead of
  /// fanning out to every enabled source. Defaults to true — the product pick.
  bool get currentSourceOnly =>
      _box.get(_currentSourceOnlyKey, defaultValue: true) as bool;

  Future<void> setCurrentSourceOnly(bool value) async {
    if (value == currentSourceOnly) return;
    await _box.put(_currentSourceOnlyKey, value);
    notifyListeners();
  }

  // ── Remembered filter/sort state (read once when a search runs) ───────────
  /// Stored by enum NAME so the index can shift without breaking persistence.
  String? get contentFilterName => _box.get(_contentFilterKey) as String?;
  Future<void> setContentFilterName(String name) =>
      _box.put(_contentFilterKey, name);

  String? get sortName => _box.get(_sortKey) as String?;
  Future<void> setSortName(String name) => _box.put(_sortKey, name);

  /// A genre keyword (e.g. "Action") or null for "Any".
  String? get genre {
    final g = _box.get(_genreKey) as String?;
    return (g == null || g.isEmpty) ? null : g;
  }

  Future<void> setGenre(String? genre) =>
      _box.put(_genreKey, genre ?? '');

  /// A decade start year (e.g. 2020 means 2020–2029) or null for "Any".
  int? get decade => _box.get(_decadeKey) as int?;
  Future<void> setDecade(int? decade) async {
    if (decade == null) {
      await _box.delete(_decadeKey);
    } else {
      await _box.put(_decadeKey, decade);
    }
  }
}
