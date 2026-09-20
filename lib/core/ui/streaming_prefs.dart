import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';
import '../metadata/streaming_service.dart';

/// `watch_region` codes TMDB accepts, common markets first. A short fixed list
/// rather than a fetch: it changes about once a year, and a picker that needs
/// the network to open is a picker that fails offline.
const List<String> kStreamingRegions = [
  'IN', 'US', 'GB', 'CA', 'AU', 'DE', 'FR', 'ES', 'IT', 'BR', //
  'MX', 'JP', 'KR', 'SG', 'AE', 'ZA', 'NL', 'SE', 'PL', 'ID',
];

/// Which country's streaming catalogue to show, and which services the user
/// pinned as Home rows.
///
/// Deliberately dumb storage, same shape as `HomeRowsPrefs`: every read is
/// synchronous and tolerant, because `TmdbCatalogue.rowTitles()` is called
/// during widget build and cannot await anything.
class StreamingPrefs {
  const StreamingPrefs._();

  static const String boxName = 'streaming_prefs';
  static const String _regionKey = 'region';
  static const String _pinnedKey = 'pinned';

  /// Each pinned service adds two TMDB calls to every Home load. Five is the
  /// point where that stops being free.
  static const int maxPinned = 5;

  /// Bumped on every write so Home reloads without resetting its scroll — same
  /// contract as `HomeRowsPrefs.revision`.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Overridable so tests never depend on the host machine's locale.
  @visibleForTesting
  static String Function() deviceRegion = _deviceRegion;

  @visibleForTesting
  static void resetDeviceRegionForTest() => deviceRegion = _deviceRegion;

  static String _deviceRegion() {
    final c = PlatformDispatcher.instance.locale.countryCode;
    return _valid(c) ? c!.toUpperCase() : 'US';
  }

  static bool _valid(String? v) =>
      v != null && v.length == 2 && RegExp(r'^[A-Za-z]{2}$').hasMatch(v);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  static Box? get _boxOrNull =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// The chosen country, or the device's. Always a valid 2-letter upper-case
  /// code: a junk stored value falls back rather than reaching the API, where
  /// it would silently return an empty catalogue.
  static String get region {
    final v = _boxOrNull?.get(_regionKey);
    return (v is String && _valid(v)) ? v.toUpperCase() : deviceRegion();
  }

  static Future<void> setRegion(String r) {
    final box = _boxOrNull;
    if (box == null || !_valid(r)) return Future.value();
    box.put(_regionKey, r.toUpperCase());
    revision.value++;
    return Future.value();
  }

  /// Services pinned as Home rows, in the order they were pinned. Unparseable
  /// entries are dropped — a blank home row is worse than a missing one.
  static List<StreamingPin> get pinned {
    final raw = (_boxOrNull?.get(_pinnedKey) as List?)?.cast<String>();
    if (raw == null) return const [];
    return [for (final e in raw) ?StreamingPin.fromEntry(e)];
  }

  static Future<void> setPinned(List<StreamingPin> pins) {
    final box = _boxOrNull;
    if (box == null) return Future.value();
    box.put(_pinnedKey, [for (final p in pins.take(maxPinned)) p.toEntry()]);
    revision.value++;
    return Future.value();
  }
}
