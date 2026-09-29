import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:watch_app/core/reading/reader_prefs.dart';

/// Per-series reading overrides for the manga reader — the "this title
/// always reads this way, regardless of my global default" escape hatch.
/// Same shape as [ReaderPrefs]: a tiny untyped Hive box, opened once during
/// bootstrap, read anywhere via `sl<ReaderOverrideStore>()`.
///
/// Each series (`sourceId:showId`) gets one Hive entry holding a small map
/// of whichever of {mode, fit} the user actually overrode — nothing entered
/// means nothing stored. An empty box makes [effectiveMode]/[effectiveFit]
/// fall straight through to the global [ReaderPrefs], so a fresh install (or
/// any title never touched here) reads exactly as it did before per-series
/// overrides existed.
class ReaderOverrideStore {
  static const String boxName = 'reader_overrides';

  /// Opens the overrides box. Call once during app bootstrap before
  /// constructing, same as [ReaderPrefs.init].
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await openBoxSafely(boxName);
    }
  }

  Box get _box => Hive.box(boxName);

  String _key(String sourceId, String showId) => '$sourceId:$showId';

  Map<String, dynamic> _entry(String sourceId, String showId) {
    final raw = _box.get(_key(sourceId, showId));
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return {};
  }

  /// Writes (or, when [value] is null, deletes) one field of a series'
  /// override entry. Drops the whole entry once it holds nothing, so a title
  /// with every override cleared leaves no trace in the box.
  Future<void> _putField(
    String sourceId,
    String showId,
    String field,
    String? value,
  ) {
    final entry = _entry(sourceId, showId);
    if (value == null) {
      entry.remove(field);
    } else {
      entry[field] = value;
    }
    if (entry.isEmpty) return _box.delete(_key(sourceId, showId));
    return _box.put(_key(sourceId, showId), entry);
  }

  /// This series' reading-direction override: 'ltr' | 'rtl' | 'vertical' —
  /// the same values `ReaderPrefs.direction` uses — or null when the title
  /// just follows the global default.
  String? modeOverride(String sourceId, String showId) =>
      _entry(sourceId, showId)['mode'] as String?;

  Future<void> setModeOverride(String sourceId, String showId, String? value) =>
      _putField(sourceId, showId, 'mode', value);

  /// This series' fit override — same value set as `ReaderPrefs.fitMode` —
  /// or null when it follows the global default.
  String? fitOverride(String sourceId, String showId) =>
      _entry(sourceId, showId)['fit'] as String?;

  Future<void> setFitOverride(String sourceId, String showId, String? value) =>
      _putField(sourceId, showId, 'fit', value);

  /// The direction this series actually reads with: its own override if
  /// set, else the global default.
  String effectiveMode(String sourceId, String showId, ReaderPrefs prefs) =>
      modeOverride(sourceId, showId) ?? prefs.direction;

  /// The fit this series actually renders with: its own override if set,
  /// else the global default.
  String effectiveFit(String sourceId, String showId, ReaderPrefs prefs) =>
      fitOverride(sourceId, showId) ?? prefs.fitMode;
}
