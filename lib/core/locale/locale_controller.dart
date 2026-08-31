import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';

/// Owns the optional UI-language override. Empty/`system` follows the device;
/// otherwise a BCP-47 tag (`en`, `ja`, `zh_CN`, `zh_TW`, …). Mirrors
/// [ThemeController]: Hive + a [revision] notifier so [MaterialApp] rebuilds.
class LocaleController {
  const LocaleController._();

  static const String boxName = 'locale_prefs';
  static const String _key = 'locale';
  static const String systemTag = 'system';

  /// Bumped whenever the override changes, so the root app rebuilds.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Selectable UI locales. First is English (source). Chinese is split into
  /// Simplified (`zh_CN`) and Traditional (`zh_TW`).
  static const List<(String tag, String nativeName)> options = [
    ('en', 'English'),
    ('ja', '日本語'),
    ('zh_CN', '简体中文'),
    ('zh_TW', '繁體中文'),
    ('es', 'Español'),
    ('de', 'Deutsch'),
    ('fr', 'Français'),
    ('it', 'Italiano'),
  ];

  static Box get _box => Hive.box(boxName);

  /// Opens the box. Call once during bootstrap, next to [ThemeController.init].
  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  /// Stored tag, or [systemTag] when following the device.
  ///
  /// Safe before [init]: the splash [MaterialApp] is built before Hive opens,
  /// so we treat an unopened box as system-default rather than throwing.
  static String get tag {
    if (!Hive.isBoxOpen(boxName)) return systemTag;
    final v = _box.get(_key) as String?;
    if (v == null || v.isEmpty) return systemTag;
    return v;
  }

  /// Whether the user left language on "System (auto)".
  static bool get followsSystem => tag == systemTag;

  /// Override for [MaterialApp.locale], or null to follow the device.
  static Locale? get locale {
    if (followsSystem) return null;
    return localeFromTag(tag);
  }

  /// Persist an override (`en`, `ja`, …) or [systemTag]/null for device.
  static Future<void> setTag(String? value) async {
    final next = (value == null || value.isEmpty) ? systemTag : value;
    if (next == tag) return;
    await _box.put(_key, next);
    revision.value++;
  }

  /// Native endonym for a stored tag, or null for system/unknown.
  static String? nativeNameFor(String storedTag) {
    for (final (t, name) in options) {
      if (t == storedTag) return name;
    }
    return null;
  }

  /// Parse a stored BCP-47-ish tag into a [Locale].
  static Locale localeFromTag(String storedTag) {
    switch (storedTag) {
      case 'zh_CN':
      case 'zh-CN':
      case 'zh_Hans':
      case 'zh-Hans':
        return const Locale('zh');
      case 'zh_TW':
      case 'zh-TW':
      case 'zh_Hant':
      case 'zh-Hant':
        return const Locale.fromSubtags(languageCode: 'zh', countryCode: 'TW');
      default:
        final parts = storedTag.split(RegExp('[-_]'));
        if (parts.length >= 2 && parts[1].isNotEmpty) {
          return Locale(parts[0], parts[1]);
        }
        return Locale(parts.first);
    }
  }

  /// Native name for whatever [resolveAppLocale] would pick for [device].
  static String nativeNameForDevice(Locale device) {
    final resolved = resolveAppLocale(device, const [
      Locale('en'),
      Locale('ja'),
      Locale('zh'),
      Locale.fromSubtags(languageCode: 'zh', countryCode: 'TW'),
      Locale('es'),
      Locale('de'),
      Locale('fr'),
      Locale('it'),
    ]);
    if (resolved.languageCode == 'zh' && resolved.countryCode == 'TW') {
      return nativeNameFor('zh_TW')!;
    }
    if (resolved.languageCode == 'zh') return nativeNameFor('zh_CN')!;
    return nativeNameFor(resolved.languageCode) ?? 'English';
  }
}

/// Map a device (or requested) locale onto a catalog we ship.
///
/// Chinese: `Hans` / CN / SG → Simplified (`zh`); `Hant` / TW / HK / MO →
/// Traditional (`zh_TW`). Anything else matches [languageCode] or English.
Locale resolveAppLocale(Locale? locale, Iterable<Locale> supported) {
  if (locale == null) return const Locale('en');

  if (locale.languageCode == 'zh') {
    final script = locale.scriptCode;
    final country = locale.countryCode;
    final traditional = script == 'Hant' ||
        country == 'TW' ||
        country == 'HK' ||
        country == 'MO';
    if (traditional) {
      return const Locale.fromSubtags(languageCode: 'zh', countryCode: 'TW');
    }
    return const Locale('zh');
  }

  for (final s in supported) {
    if (s.languageCode != locale.languageCode) continue;
    if (s.countryCode == null ||
        s.countryCode == locale.countryCode ||
        locale.countryCode == null) {
      return s;
    }
  }
  for (final s in supported) {
    if (s.languageCode == locale.languageCode) return s;
  }
  return const Locale('en');
}
