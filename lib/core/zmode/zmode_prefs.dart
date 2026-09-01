import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../hive/safe_box.dart';

/// Which kind of streaming catalogue Zangetsu Mode shows while the content
/// mode is `anime`. Movie/TV isn't a `ContentMode` of its own on purpose:
/// adding one would ripple through a dozen exhaustive switches, and the
/// distinction only exists when the toggle is on.
enum StreamKind { anime, movie }

/// The Zangetsu Mode toggle. Off = the app exactly as it is without it.
/// Same shape as `LocaleController`: Hive box + a revision notifier the shell
/// listens to.
class ZModePrefs {
  const ZModePrefs._();

  static const String boxName = 'zmode_prefs';
  static const String _kEnabled = 'enabled';
  static const String _kStreamKind = 'streamKind';

  /// Bumped on every change so listeners can rebuild.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
    // Anyone who turned the mode OFF while the toggle existed still has that
    // false on disk, and the default only applies to an absent key — so
    // without this they would be stranded in the source-only app with no
    // control left to bring them back. Clearing the key once puts them on the
    // same footing as a fresh install.
    final box = _boxOrNull;
    if (box != null && box.get(_kEnabled) == false) {
      await box.delete(_kEnabled);
      revision.value++;
    }
  }

  static Box? get _boxOrNull =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// On for everyone. The metadata catalogue is how the app browses now, and
  /// the Settings toggle that used to turn it off is gone.
  ///
  /// The stored key is still read by [setEnabled] so tests can exercise the
  /// source-only path, which still exists underneath — but nothing in the UI
  /// can reach it, so a fresh install and an upgrade both land here.
  static bool get enabled =>
      (_boxOrNull?.get(_kEnabled, defaultValue: true) as bool?) ?? true;

  static Future<void> setEnabled(bool value) async {
    if (value == enabled) return;
    await Hive.box(boxName).put(_kEnabled, value);
    revision.value++;
  }

  static StreamKind get streamKind {
    final v = _boxOrNull?.get(_kStreamKind) as String?;
    return v == StreamKind.movie.name ? StreamKind.movie : StreamKind.anime;
  }

  static Future<void> setStreamKind(StreamKind kind) async {
    if (kind == streamKind) return;
    await Hive.box(boxName).put(_kStreamKind, kind.name);
    revision.value++;
  }
}
