import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';

import 'dock_visibility.dart';

/// The app's toast — a dark pill above the dock.
///
/// The app deliberately doesn't use SnackBars: they push content, sit under
/// the floating dock, and look nothing like the rest of the chrome. This was
/// copy-pasted in three places before it earned a home.
void showAppToast(BuildContext context, String message) {
  (FToast()..init(context)).showToast(
    gravity: ToastGravity.BOTTOM,
    toastDuration: _duration,
    child: Padding(
      // Clears the dock, which floats over content — the same figure the
      // shell's exit toast uses.
      padding: EdgeInsets.only(
        bottom: kDockClearance + MediaQuery.paddingOf(context).bottom,
        left: 24,
        right: 24,
      ),
      child: _pill(message),
    ),
  );
}

/// The same pill, for a caller that has no widget context of its own — a
/// global callback fired from a service rather than from a screen.
///
/// It inserts into [overlay] directly instead of going through [showAppToast],
/// because that resolves the overlay with `Overlay.of(context)`, which searches
/// a context's ANCESTORS. Neither context reachable from a navigator key works:
/// the key's own context sits above the overlay, and the overlay's context
/// cannot find itself. Both throw "Overlay is null", which is how the Z Mode
/// provider-fallback notice silently never appeared.
VoidCallback showAppToastIn(OverlayState overlay, String message) {
  var dismissed = false;
  Timer? timer;
  late final OverlayEntry entry;
  void dismiss() {
    if (dismissed) return;
    dismissed = true;
    timer?.cancel();
    if (!overlay.mounted) return;
    try {
      entry.remove();
    } on AssertionError {
      // The overlay already detached this transient entry.
    } on TypeError {
      // Release builds report a repeated remove as a null-check error.
    }
  }

  entry = OverlayEntry(
    builder: (context) => Positioned(
      left: 24,
      right: 24,
      bottom: kDockClearance + MediaQuery.paddingOf(context).bottom,
      // Never eat a tap: this is a notice, and it floats over live content.
      child: IgnorePointer(
        // An overlay entry has no Material above it, and text without one
        // renders in Flutter's debug style — monospace with a yellow
        // underline. [showAppToast] never hit this because FToast wraps its
        // own child.
        child: Material(
          type: MaterialType.transparency,
          child: Center(child: _pill(message)),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  timer = Timer(_duration, dismiss);
  return dismiss;
}

const Duration _duration = Duration(seconds: 2);

Widget _pill(String message) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
  decoration: BoxDecoration(
    color: const Color(0xF01C1C1E),
    borderRadius: BorderRadius.circular(24),
  ),
  child: Text(
    message,
    textAlign: TextAlign.center,
    style: const TextStyle(color: Colors.white, fontSize: 14),
  ),
);
