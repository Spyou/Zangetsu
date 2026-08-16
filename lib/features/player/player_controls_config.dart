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
/// section. The first seven are on the bar by default; the rest live in the
/// ⋮ More sheet and can be promoted onto it.
const List<PlayerControl> kPlayerControls = [
  PlayerControl('speed', 'Speed', Icons.speed_rounded),
  PlayerControl('tracks', 'Audio & subs', Icons.subtitles_rounded),
  PlayerControl('quality', 'Quality', Icons.high_quality_rounded),
  PlayerControl('sources', 'Sources', Icons.layers_rounded),
  PlayerControl('more', 'More', Icons.more_vert_rounded, pinned: true),
  PlayerControl('episodes', 'Episodes', Icons.video_library_outlined),
  PlayerControl('fit', 'Aspect ratio', Icons.fit_screen_rounded),
  PlayerControl('decoder', 'Decoder', Icons.memory_rounded),
  PlayerControl('enhance', 'Anime4K', Icons.auto_awesome_rounded),
  PlayerControl('colour', 'Colour', Icons.palette_outlined),
  PlayerControl('snapshot', 'Snapshot', Icons.photo_camera_rounded),
  PlayerControl('sleep', 'Sleep timer', Icons.bedtime_outlined),
  PlayerControl('pip', 'Picture-in-picture', Icons.picture_in_picture_alt_rounded),
];

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
  const PlayerControlsConfig({required this.left, required this.right});

  final List<String> left;
  final List<String> right;

  /// What the bar looks like out of the box — exactly the layout that shipped
  /// before this screen existed, so nobody's player changes unless they ask.
  static const List<String> defaultLeft = [
    'speed',
    'tracks',
    'quality',
    'sources',
    'more',
  ];
  static const List<String> defaultRight = ['episodes', 'fit'];

  static const PlayerControlsConfig defaults = PlayerControlsConfig(
    left: defaultLeft,
    right: defaultRight,
  );

  /// Everything not placed on either side, in registry order.
  List<String> get hidden => [
    for (final c in kPlayerControls)
      if (!left.contains(c.id) && !right.contains(c.id)) c.id,
  ];

  /// Drops ids we no longer know about (a layout saved by a newer build, or a
  /// control since removed) and forces the pinned ones back on if they've gone
  /// missing, so a bad or stale save can't leave someone stranded.
  PlayerControlsConfig sanitised() {
    bool known(String id) => controlById(id) != null;
    final l = left.where(known).toList();
    final r = right.where(known).toList();
    for (final c in kPlayerControls) {
      if (c.pinned && !l.contains(c.id) && !r.contains(c.id)) l.add(c.id);
    }
    return PlayerControlsConfig(left: l, right: r);
  }
}
