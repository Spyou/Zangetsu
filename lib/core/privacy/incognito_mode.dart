import 'package:flutter/foundation.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive/hive.dart';

/// Global "pause recording me" switch. While on, the app stops writing anything
/// that tracks you: search history, watch history, resume positions, tracker
/// auto-scrobble, and Discord presence. Explicit actions you take yourself
/// (e.g. editing a tracker list by hand) are unaffected.
///
/// [notifier] drives the top-bar indicator; [on] is a fast synchronous read for
/// the one-line guards at each recording site. Persisted, so it survives a
/// restart until you turn it off.
abstract final class IncognitoMode {
  static const String boxName = 'privacy_prefs';
  static const String _key = 'incognito';

  static final ValueNotifier<bool> notifier = ValueNotifier<bool>(false);

  static bool get on => notifier.value;

  static Future<void> init() async {
    final box = Hive.isBoxOpen(boxName)
        ? Hive.box(boxName)
        : await openBoxSafely(boxName);
    notifier.value = box.get(_key, defaultValue: false) as bool;
  }

  static Future<void> set(bool value) async {
    if (value == notifier.value) return;
    notifier.value = value;
    final box = Hive.isBoxOpen(boxName)
        ? Hive.box(boxName)
        : await openBoxSafely(boxName);
    await box.put(_key, value);
  }
}
