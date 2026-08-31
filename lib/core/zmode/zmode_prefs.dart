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
  static const String _kSourcesMode = 'sourcesMode';

  /// Bumped on every change so listeners can rebuild.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<void> init() async {
    if (!Hive.isBoxOpen(boxName)) await openBoxSafely(boxName);
  }

  static Box? get _boxOrNull =>
      Hive.isBoxOpen(boxName) ? Hive.box(boxName) : null;

  /// Safe before [init] (the splash reads prefs before Hive is up): an
  /// unopened box means off.
  static bool get enabled =>
      (_boxOrNull?.get(_kEnabled, defaultValue: false) as bool?) ?? false;

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

  /// Sources is a selectable mode alongside Anime/Movie-TV/Manga/Novel, not a
  /// `ContentMode` value — see the module doc comment on why. When true, Home
  /// and Search are source-driven (the installed sources) instead of the
  /// metadata catalogue, exactly like Z Mode off.
  static bool get sourcesMode =>
      (_boxOrNull?.get(_kSourcesMode, defaultValue: false) as bool?) ?? false;

  static Future<void> setSourcesMode(bool value) async {
    if (value == sourcesMode) return;
    await Hive.box(boxName).put(_kSourcesMode, value);
    revision.value++;
  }
}
