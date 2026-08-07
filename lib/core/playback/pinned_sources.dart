import 'package:flutter/foundation.dart';
import 'package:watch_app/core/hive/safe_box.dart';
import 'package:hive/hive.dart';

/// Source IDs the user pinned to the top of the source picker. Device-local,
/// order preserved (newest pin last). [notifier] lets the picker rebuild live.
abstract final class PinnedSources {
  static const String boxName = 'pinned_sources';
  static const String _key = 'ids';

  static final ValueNotifier<List<String>> notifier = ValueNotifier(const []);

  static Future<void> init() async {
    final box = Hive.isBoxOpen(boxName)
        ? Hive.box(boxName)
        : await openBoxSafely(boxName);
    final raw = box.get(_key);
    notifier.value = raw is List
        ? raw.map((e) => '$e').where((e) => e.isNotEmpty).toList()
        : const [];
  }

  static bool isPinned(String id) => notifier.value.contains(id);

  static Future<void> toggle(String id) async {
    final list = List<String>.of(notifier.value);
    if (!list.remove(id)) list.add(id);
    notifier.value = list;
    final box = Hive.isBoxOpen(boxName)
        ? Hive.box(boxName)
        : await openBoxSafely(boxName);
    await box.put(_key, list);
  }
}
