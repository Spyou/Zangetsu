import 'package:flutter/material.dart';

/// The set of player bottom-bar controls the user can arrange.
///
/// One list, shared by the player and the Settings screen that reorders them,
/// so the two can't drift apart: adding a control here is all it takes for it
/// to appear in Settings, and it lands in Hidden until someone puts it on the
/// bar (see [PlayerControlsConfig.hidden]).
class PlayerControl {
  const PlayerControl(this.id, this.label, this.icon, {this.pinned = false});

  /// Stable key written to prefs — never rename one of these, it's what a
  /// user's saved layout refers to.
  final String id;
  final String label;
  final IconData icon;

  /// Can be moved and reordered but never hidden. Only ⋮ More, which is the
  /// way back to everything sitting in Hidden — without it you could hide
  /// your way into a bar with no route to the controls you put away.
  final bool pinned;
}

/// Every arrangeable control, in the order they appear in Settings' Hidden
/// section.
///
/// Back, Lock and Settings are deliberately absent: they're fixed in the top
/// bar. Losing the way out of the player, or the route to the screen that
/// arranges all this, isn't something to leave one tap away behind a toggle.
const List<PlayerControl> kPlayerControls = [
  PlayerControl('speed', 'Speed', Icons.speed_rounded),
  PlayerControl('tracks', 'Audio & subs', Icons.subtitles_rounded),
  PlayerControl('quality', 'Quality', Icons.high_quality_rounded),
  PlayerControl('sources', 'Sources', Icons.layers_rounded),
  PlayerControl('more', 'More', Icons.more_vert_rounded, pinned: true),
  PlayerControl('episodes', 'Episodes', Icons.video_library_outlined),
  PlayerControl('fit', 'Aspect ratio', Icons.fit_screen_rounded),
  PlayerControl('cast', 'Cast', Icons.cast),
  PlayerControl('info', 'Playback stats', Icons.info_outline_rounded),
  PlayerControl('decoder', 'Decoder', Icons.memory_rounded),
  PlayerControl('enhance', 'Anime4K', Icons.auto_awesome_rounded),
  PlayerControl('colour', 'Colour', Icons.palette_outlined),
  PlayerControl('snapshot', 'Snapshot', Icons.photo_camera_rounded),
  PlayerControl('sleep', 'Sleep timer', Icons.bedtime_outlined),
  PlayerControl('pip', 'Picture-in-picture', Icons.picture_in_picture_alt_rounded),
];

/// Where a control can be put.
enum ControlSlot { top, left, right, hidden }

extension ControlSlotLabel on ControlSlot {
  String get label => switch (this) {
    ControlSlot.top => 'Top bar',
    ControlSlot.left => 'Left side',
    ControlSlot.right => 'Right side',
    ControlSlot.hidden => 'Hidden',
  };
}

PlayerControl? controlById(String id) {
  for (final c in kPlayerControls) {
    if (c.id == id) return c;
  }
  return null; // an id from a newer build, or one we've since removed
}

/// A user's bar layout: what sits on the left, what sits on the right, and —
/// by subtraction — what's hidden.
///
/// Hidden is derived rather than stored, which is what makes this survive app
/// updates: a control added in a later version simply isn't in either saved
/// list, so it falls into Hidden on its own. Storing all three lists would
/// mean migrating every saved layout each time we add a button.
class PlayerControlsConfig {
  const PlayerControlsConfig({
    required this.top,
    required this.left,
    required this.right,
  });

  final List<String> top;
  final List<String> left;
  final List<String> right;

  /// What the player looks like out of the box — exactly the layout that
  /// shipped before this screen existed, so nobody's player changes unless
  /// they ask it to.
  /// The top bar shares its row with the show title, plus the fixed back,
  /// lock and settings buttons. Past five the title has no room left, so this
  /// is a hard cap rather than something to discover in the player.
  static const int maxTop = 5;

  static const List<String> defaultTop = ['cast', 'info'];
  static const List<String> defaultLeft = [
    'speed',
    'tracks',
    'quality',
    'sources',
    'more',
  ];
  static const List<String> defaultRight = ['episodes', 'fit'];

  static const PlayerControlsConfig defaults = PlayerControlsConfig(
    top: defaultTop,
    left: defaultLeft,
    right: defaultRight,
  );

  /// Everything not placed anywhere, in registry order.
  List<String> get hidden => [
    for (final c in kPlayerControls)
      if (!top.contains(c.id) &&
          !left.contains(c.id) &&
          !right.contains(c.id))
        c.id,
  ];

  List<String> forSlot(ControlSlot slot) => switch (slot) {
    ControlSlot.top => top,
    ControlSlot.left => left,
    ControlSlot.right => right,
    ControlSlot.hidden => hidden,
  };

  ControlSlot slotOf(String id) {
    if (top.contains(id)) return ControlSlot.top;
    if (left.contains(id)) return ControlSlot.left;
    if (right.contains(id)) return ControlSlot.right;
    return ControlSlot.hidden;
  }

  /// Drops ids we no longer know about (a layout saved by a newer build, or a
  /// control since removed), removes any duplicate that ended up in two slots,
  /// and forces the pinned ones back if they've gone missing — so a stale or
  /// bad save can't leave someone with no route to what they put away.
  PlayerControlsConfig sanitised() {
    final seen = <String>{};
    List<String> clean(List<String> ids) => [
      for (final id in ids)
        if (controlById(id) != null && seen.add(id)) id,
    ];
    final t = clean(top);
    final l = clean(left);
    final r = clean(right);
    // An over-full top bar (an older save, or one written by a build with a
    // higher cap) drops its extras rather than squeezing the title to nothing.
    // They fall to Hidden, which is recoverable — ⋮ More reaches everything.
    if (t.length > maxTop) t.removeRange(maxTop, t.length);
    for (final c in kPlayerControls) {
      if (c.pinned && !seen.contains(c.id)) l.add(c.id);
    }
    return PlayerControlsConfig(top: t, left: l, right: r);
  }
}
