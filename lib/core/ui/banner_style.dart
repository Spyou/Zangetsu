import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

/// One selectable Home banner.
class BannerStyleOption {
  const BannerStyleOption({
    required this.id,
    required this.label,
    required this.blurb,
  });

  /// Persisted — never rename. Matches [BannerStyle.options].
  final String id;
  final String label;

  /// One line under the card in the picker.
  final String blurb;
}

/// Which banner Home draws behind the floating header.
///
/// Shaped like [SplashStyle] next to it in Settings, and for the same reason:
/// the choice is persisted, so the ids are permanent once shipped.
///
/// [defaultId] is the card banner every install already wears, drawn by the
/// widget it has always been drawn by. The alternative lives in its own file
/// and only builds when someone picks it, so choosing nothing leaves the Home
/// screen byte-identical to the one before this feature existed.
class BannerStyle {
  BannerStyle._();

  static const String boxName = 'app_prefs';
  static const String _key = 'homeBannerStyle';

  static const String defaultId = 'card';
  static const String panelsId = 'panels';

  /// [defaultId] first, so the picker leads with what a fresh install wears.
  static const List<BannerStyleOption> options = [
    BannerStyleOption(
      id: defaultId,
      label: 'Card',
      blurb: 'The banner you have now',
    ),
    BannerStyleOption(id: panelsId, label: 'Panels', blurb: 'A manga spread'),
  ];

  /// Falls back to [defaultId] for anything unknown, so a build that drops an
  /// option can't leave Home with no banner to draw.
  static String get selectedId {
    if (!Hive.isBoxOpen(boxName)) return defaultId;
    final v = Hive.box(boxName).get(_key);
    if (v is String && options.any((o) => o.id == v)) return v;
    return defaultId;
  }

  /// The live value Home listens to.
  ///
  /// The splash can afford to read its pref once at launch — it is only on
  /// screen at launch. This one is a tap and a back-press away from being
  /// looked at, so Home rebuilds on the change instead of waiting for a cold
  /// start and looking broken in between.
  ///
  /// Lazy on purpose: the first read happens when Home builds, by which point
  /// bootstrap has opened the box.
  static final ValueNotifier<String> current = ValueNotifier<String>(
    selectedId,
  );

  static Future<void> select(String id) async {
    if (!options.any((o) => o.id == id)) return;
    if (!Hive.isBoxOpen(boxName)) return;
    await Hive.box(boxName).put(_key, id);
    current.value = id;
  }
}
