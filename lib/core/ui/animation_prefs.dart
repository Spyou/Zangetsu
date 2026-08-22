import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

/// How a list/grid card enters. [rise] is the default — the fade + lift that
/// reads as motion without being showy; the other two are for people who want
/// either less movement or more.
enum ListAnimStyle {
  /// Fade in while lifting and scaling up slightly. The default.
  rise,

  /// Opacity only. The quietest option that's still an animation — for anyone
  /// who finds movement distracting but doesn't want cards snapping in.
  fade,

  /// Scale up from noticeably smaller, no travel. The showiest of the three.
  zoom,
}

/// List/grid entrance settings: whether cards animate in, and which way.
///
/// [listAnimations] and [style] are held in memory so [RevealItem] can read
/// them per-item for free; Hive is only touched at init and when the user
/// changes something.
class AnimationPrefs {
  static const String boxName = 'ui_prefs';
  static const String _key = 'listAnimations';
  static const String _styleKey = 'listAnimStyle';

  /// Live value read by every reveal. On by default; off means cards appear
  /// with no animation at all.
  static bool listAnimations = true;

  /// Which entrance to use when [listAnimations] is on.
  static ListAnimStyle style = ListAnimStyle.rise;

  /// Bumped when either setting changes, so the Appearance screen (and
  /// anything else that cares) can rebuild. Cards already revealed keep
  /// whatever they were revealed with — a change applies as you scroll on.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<Box> _open() async => Hive.isBoxOpen(boxName)
      ? Hive.box(boxName)
      : await openBoxSafely(boxName);

  static Future<void> init() async {
    final box = await _open();
    listAnimations = box.get(_key, defaultValue: true) as bool;
    style = _styleFromName(box.get(_styleKey) as String?);
  }

  static Future<void> setListAnimations(bool value) async {
    listAnimations = value;
    revision.value++;
    await (await _open()).put(_key, value);
  }

  static Future<void> setStyle(ListAnimStyle value) async {
    style = value;
    revision.value++;
    await (await _open()).put(_styleKey, value.name);
  }

  /// Unknown/absent name falls back to the default rather than throwing — an
  /// older install has no stored style, and a value written by a newer build
  /// shouldn't break an older one.
  @visibleForTesting
  static ListAnimStyle styleFromNameForTest(String? name) =>
      _styleFromName(name);

  static ListAnimStyle _styleFromName(String? name) => switch (name) {
        'fade' => ListAnimStyle.fade,
        'zoom' => ListAnimStyle.zoom,
        _ => ListAnimStyle.rise,
      };
}
