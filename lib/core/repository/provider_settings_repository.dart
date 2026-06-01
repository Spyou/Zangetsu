import 'package:hive/hive.dart';

/// Persists per-source user-chosen settings.
///
/// Keyed by the composite `'$repoUrl::$sourceId'` provider key (see
/// [ProviderRegistry.providerKey]) so two repos publishing the same
/// `sourceId` keep separate settings. Values are `Map<String, dynamic>`
/// of `{settingKey: value}` — schema parsing happens in the UI layer,
/// the store is intentionally schema-agnostic so a provider can rename /
/// drop settings without invalidating the rest of the saved state.
class ProviderSettingsRepository {
  static const String boxName = 'provider_settings';

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<Map>(boxName);
    }
  }

  Box<Map> get _box => Hive.box<Map>(boxName);

  /// Returns the saved settings for the composite [key], or an empty map
  /// if no row exists. Callers blend this on top of the schema's
  /// defaults — `getFor` deliberately does NOT seed defaults so the JS
  /// side can distinguish "user picked this" from "user hasn't touched it".
  Map<String, dynamic> getFor(String key) {
    final raw = _box.get(key);
    if (raw == null) return <String, dynamic>{};
    return Map<String, dynamic>.from(raw);
  }

  /// Replaces the stored settings for the composite [key]. Pass an empty
  /// map to wipe — that's still meaningfully different from [clearFor],
  /// which deletes the row entirely.
  Future<void> setFor(String key, Map<String, dynamic> settings) async {
    await _box.put(key, settings);
  }

  Future<void> clearFor(String key) async {
    await _box.delete(key);
  }

  /// All installed provider keys → their saved settings. Used at boot
  /// to push every saved row into the JS runtime in one pass.
  Map<String, Map<String, dynamic>> getAll() {
    final out = <String, Map<String, dynamic>>{};
    for (final raw in _box.keys) {
      final k = raw.toString();
      final stored = _box.get(raw);
      if (stored == null) continue;
      try {
        out[k] = Map<String, dynamic>.from(stored);
      } catch (_) {
        // Skip corrupt rows — the form regenerates them on next save.
      }
    }
    return out;
  }

  Stream<BoxEvent> watch() => _box.watch();
}
