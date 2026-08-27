import 'dart:convert';

import 'package:flutter/painting.dart';

/// What a tap somewhere on the page does.
enum ReaderAction {
  none,
  nextPage,
  prevPage,
  toggleMenu,
  scrollUp,
  scrollDown,
  nextChapter,
  prevChapter,
}

extension ReaderActionLabel on ReaderAction {
  String get label => switch (this) {
    ReaderAction.none => 'Nothing',
    ReaderAction.nextPage => 'Next page',
    ReaderAction.prevPage => 'Previous page',
    ReaderAction.toggleMenu => 'Show/hide controls',
    ReaderAction.scrollUp => 'Scroll up',
    ReaderAction.scrollDown => 'Scroll down',
    ReaderAction.nextChapter => 'Next chapter',
    ReaderAction.prevChapter => 'Previous chapter',
  };

  /// Paging is the only thing that means something different in right-to-left
  /// reading, so it's the only thing [TapZoneLayout.actionAt] mirrors.
  bool get isPaging =>
      this == ReaderAction.nextPage || this == ReaderAction.prevPage;

  ReaderAction get mirrored => switch (this) {
    ReaderAction.nextPage => ReaderAction.prevPage,
    ReaderAction.prevPage => ReaderAction.nextPage,
    _ => this,
  };
}

/// One rectangle of the page and what tapping it does.
///
/// [bounds] is normalised 0..1 on both axes, so a layout is independent of
/// screen size, orientation and device.
class TapZone {
  const TapZone({required this.bounds, required this.action});

  final Rect bounds;
  final ReaderAction action;

  bool contains(Offset normalised) => bounds.contains(normalised);

  Map<String, dynamic> toJson() => {
    'l': bounds.left,
    't': bounds.top,
    'r': bounds.right,
    'b': bounds.bottom,
    'a': action.name,
  };

  static TapZone? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    double? num_(Object? v) => v is num ? v.toDouble() : null;
    final l = num_(raw['l']);
    final t = num_(raw['t']);
    final r = num_(raw['r']);
    final b = num_(raw['b']);
    if (l == null || t == null || r == null || b == null) return null;
    if (r <= l || b <= t) return null; // a zone with no area can never be hit
    return TapZone(
      bounds: Rect.fromLTRB(l, t, r, b),
      action: ReaderAction.values.firstWhere(
        (e) => e.name == raw['a'],
        orElse: () => ReaderAction.none,
      ),
    );
  }
}

/// The set of zones for one reading mode.
class TapZoneLayout {
  const TapZoneLayout({
    required this.id,
    required this.name,
    required this.zones,
  });

  /// One per reading mode the app actually has: 'ltr' and 'rtl' share
  /// [paged] (the difference is mirroring, not a second set of zones), and
  /// 'vertical' is a continuous strip.
  static const String paged = 'paged';
  static const String webtoon = 'webtoon';

  static const List<String> ids = [paged, webtoon];

  final String id;
  final String name;
  final List<TapZone> zones;

  /// The action for a tap at [normalised] (0..1 on both axes).
  ///
  /// Searched last-to-first so a zone added later sits on top of the ones
  /// under it, which is what lets zones overlap without an explicit z-order.
  /// [rtl] mirrors paging only — "scroll down" still means down.
  ReaderAction actionAt(Offset normalised, {bool rtl = false}) {
    for (var i = zones.length - 1; i >= 0; i--) {
      if (zones[i].contains(normalised)) {
        final a = zones[i].action;
        return rtl && a.isPaging ? a.mirrored : a;
      }
    }
    return ReaderAction.none;
  }

  TapZoneLayout withZoneAction(int index, ReaderAction action) {
    if (index < 0 || index >= zones.length) return this;
    return TapZoneLayout(
      id: id,
      name: name,
      zones: [
        for (var i = 0; i < zones.length; i++)
          i == index
              ? TapZone(bounds: zones[i].bounds, action: action)
              : zones[i],
      ],
    );
  }

  String toJsonString() =>
      jsonEncode({'id': id, 'zones': [for (final z in zones) z.toJson()]});

  /// Parses a saved layout, falling back to the default for [id] if the stored
  /// value is missing, corrupt, or has no usable zones — a bad layout would
  /// otherwise leave the reader with a screen that does nothing at all.
  static TapZoneLayout fromJsonString(String? raw, String id) {
    if (raw == null || raw.isEmpty) return defaultFor(id);
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return defaultFor(id);
      final zones = (map['zones'] as List? ?? const [])
          .map(TapZone.fromJson)
          .whereType<TapZone>()
          .toList();
      if (zones.isEmpty) return defaultFor(id);
      return TapZoneLayout(id: id, name: defaultFor(id).name, zones: zones);
    } catch (_) {
      return defaultFor(id);
    }
  }

  static TapZoneLayout defaultFor(String id) => switch (id) {
    webtoon => _defaultWebtoon,
    _ => _defaultPaged,
  };

  /// Left third back, right third forward, middle for the controls — the
  /// layout every manga reader uses, and what this reader did before zones
  /// were configurable.
  static const TapZoneLayout _defaultPaged = TapZoneLayout(
    id: paged,
    name: 'Paged',
    zones: [
      TapZone(
        bounds: Rect.fromLTRB(0, 0, 0.33, 1),
        action: ReaderAction.prevPage,
      ),
      TapZone(
        bounds: Rect.fromLTRB(0.33, 0, 0.67, 1),
        action: ReaderAction.toggleMenu,
      ),
      TapZone(
        bounds: Rect.fromLTRB(0.67, 0, 1, 1),
        action: ReaderAction.nextPage,
      ),
    ],
  );

  /// A long strip has no pages to turn, so the top and bottom scroll instead.
  /// Tapping used to do nothing here but open the controls.
  static const TapZoneLayout _defaultWebtoon = TapZoneLayout(
    id: webtoon,
    name: 'Webtoon',
    zones: [
      TapZone(
        bounds: Rect.fromLTRB(0, 0, 1, 0.33),
        action: ReaderAction.scrollUp,
      ),
      TapZone(
        bounds: Rect.fromLTRB(0, 0.33, 1, 0.67),
        action: ReaderAction.toggleMenu,
      ),
      TapZone(
        bounds: Rect.fromLTRB(0, 0.67, 1, 1),
        action: ReaderAction.scrollDown,
      ),
    ],
  );

  /// Which layout a reading mode uses.
  ///
  /// Takes the reader's own mode values ('ltr' | 'rtl' | 'vertical'). The
  /// newer `readingMode` spellings are accepted too: that key isn't wired up
  /// anywhere yet, and a mode name silently falling through to the paged
  /// layout is exactly the bug this had — left/right zones firing `nextPage`
  /// at a strip with no pages to turn.
  static String idForReadingMode(String mode) => switch (mode) {
    'vertical' || 'webtoon' || 'vertical_paged' => webtoon,
    _ => paged,
  };
}
