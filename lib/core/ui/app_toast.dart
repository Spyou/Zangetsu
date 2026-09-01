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
    toastDuration: const Duration(seconds: 2),
    child: Container(
      // Clears the dock, which floats over content — the same figure the
      // shell's exit toast uses.
      margin: EdgeInsets.only(
        bottom: kDockClearance + MediaQuery.paddingOf(context).bottom,
        left: 24,
        right: 24,
      ),
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
    ),
  );
}
