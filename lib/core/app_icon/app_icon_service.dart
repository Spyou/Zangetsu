import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

/// One selectable home-screen icon.
class AppIconOption {
  const AppIconOption({
    required this.id,
    required this.label,
    required this.asset,
  });

  /// Matches the key in MainActivity.ICON_ALIASES. Persisted — never rename.
  final String id;
  final String label;

  /// Preview shown in Settings (a bundled asset, not the launcher resource —
  /// mipmaps aren't reachable from Dart).
  final String asset;
}

/// Switches the launcher icon between the manifest's `<activity-alias>` entries.
///
/// Android bakes the launcher icon into the manifest at install time, so it
/// can't be swapped at runtime. The only supported approach is to declare one
/// alias per icon and enable exactly one — which is what the native side does.
///
/// Android-only. Everywhere else [supported] is false and the setting is hidden;
/// iOS has its own unrelated API and TV has no icon picker at all.
class AppIconService {
  static const _ch = MethodChannel('zangetsu/app_icon');
  static const String boxName = 'app_prefs';
  static const String _key = 'appIconId';

  /// The icon a fresh install shows — i.e. the alias that ships
  /// `android:enabled="true"`. NOT the same thing as the option whose id
  /// happens to be the string `'default'`: that id is the older Z-and-katana
  /// mark and is persisted, so it can never be renamed — which is exactly why
  /// the crescent got its own id rather than taking that slot. Anyone who had
  /// picked an icon keeps the one they picked. Keep this in step with the
  /// manifest and with `MainActivity.currentIconAlias()`'s fallback — all three
  /// have to name the same icon, or the launcher shows one thing while Settings
  /// claims another.
  static const String defaultId = 'crescent';

  /// [defaultId] first — the picker leads with what a fresh install is
  /// actually wearing.
  static const List<AppIconOption> options = [
    AppIconOption(
      id: 'crescent',
      label: 'Zangetsu',
      asset: 'assets/icon/preview_crescent.png',
    ),
    AppIconOption(
      id: 'default',
      label: 'Katana',
      asset: 'assets/icon/preview_default.png',
    ),
    AppIconOption(
      id: 'classic',
      label: 'Classic',
      asset: 'assets/icon/preview_classic.png',
    ),
  ];

  /// Icon switching only exists on Android.
  ///
  /// A function rather than a plain getter so tests can reach the logic behind
  /// it — everything here is gated on this, so on a test host the whole service
  /// would otherwise be unreachable. Mirrors `StreamingPrefs.deviceRegion`.
  static bool Function() isSupported = _isSupported;
  static bool _isSupported() => Platform.isAndroid;

  @visibleForTesting
  static void resetSupportedForTest() => isSupported = _isSupported;

  bool get supported => isSupported();

  Box get _box => Hive.box(boxName);

  /// The selected icon id. Falls back to [defaultId] for anything unknown, so a
  /// build that drops an option can't leave the UI with no selection.
  String get selectedId {
    final v = _box.get(_key);
    if (v is String && options.any((o) => o.id == v)) return v;
    return defaultId;
  }

  /// Applies [id] and remembers it.
  ///
  /// Android usually kills the app here: disabling the component the current
  /// task was launched from tears that task down. Callers must warn first.
  /// The preference is written BEFORE the native call so the choice survives
  /// even when the process dies mid-switch.
  Future<void> select(String id) async {
    if (!supported) return;
    if (!options.any((o) => o.id == id)) return;
    await _box.put(_key, id);
    await _ch.invokeMethod<bool>('set', {'id': id});
  }

  /// The alias actually enabled right now, straight from PackageManager.
  /// Null when it can't be read. Used to reconcile the pref with reality — a
  /// switch that was interrupted can leave the two disagreeing.
  Future<String?> nativeCurrent() async {
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<String>('current');
    } catch (_) {
      return null;
    }
  }

  /// [selectedId], corrected against what PackageManager actually has enabled,
  /// and the stored pref rewritten to match.
  ///
  /// The pref alone is not the truth. It can disagree with the launcher in ways
  /// the user never did anything to cause:
  ///
  ///  * a switch was interrupted — Android kills the app mid-switch by design,
  ///    and the pref is deliberately written first so the *intent* survives;
  ///  * an update changed which alias ships enabled, while the pref still names
  ///    the icon the previous build shipped.
  ///
  /// Either way Settings would show a tick next to an icon that is not on the
  /// home screen. PackageManager wins, because it is what the user can see.
  ///
  /// Returns [selectedId] unchanged when the native side can't be read, so a
  /// failure here never rewrites a good preference.
  Future<String> reconciledId() async {
    final actual = await nativeCurrent();
    if (actual == null || !options.any((o) => o.id == actual)) {
      return selectedId;
    }
    if (_box.get(_key) != actual) await _box.put(_key, actual);
    return actual;
  }
}
