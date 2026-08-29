import 'dart:io';

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
  /// happens to be the string `'default'`: that id is the Zangetsu mark and is
  /// persisted, so it can never be renamed. Keep this in step with the manifest
  /// and with `MainActivity.currentIconAlias()`'s fallback — all three have to
  /// name the same icon or the launcher shows one thing while Settings claims
  /// another.
  static const String defaultId = 'classic';

  /// [defaultId] first — the picker leads with what a fresh install is
  /// actually wearing.
  static const List<AppIconOption> options = [
    AppIconOption(
      id: 'classic',
      label: 'Classic',
      asset: 'assets/icon/preview_classic.png',
    ),
    AppIconOption(
      id: 'default',
      label: 'Zangetsu',
      asset: 'assets/icon/preview_default.png',
    ),
  ];

  /// Icon switching only exists on Android.
  bool get supported => Platform.isAndroid;

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
}
