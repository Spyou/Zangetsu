import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../tv/tv_alert_dialog.dart';

export '../tv/tv_alert_dialog.dart' show TvAlertAction, TvAlertDialog;

/// App-wide OK / yes-no / custom-action popups.
///
/// Always uses the TV-friendly chrome ([TvAlertDialog]) — compact on a phone,
/// 10-foot + D-pad trapped on TV. Call sites never branch on [AppMode].
abstract final class AppDialog {
  /// Lowest-level entry: title, body, actions. Prefer [alert] / [confirm]
  /// unless the buttons are not a plain OK or Cancel/Confirm pair.
  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    required Widget body,
    required List<TvAlertAction> actions,
    bool barrierDismissible = true,
  }) {
    return showTvAlertDialog<T>(
      context,
      title: title,
      body: body,
      actions: actions,
      barrierDismissible: barrierDismissible,
    );
  }

  /// Single-button notice. Dismisses with OK (or [okLabel]).
  static Future<void> alert(
    BuildContext context, {
    required String title,
    String? message,
    Widget? body,
    String? okLabel,
    bool barrierDismissible = true,
  }) {
    assert(
      message != null || body != null,
      'AppDialog.alert needs message or body',
    );
    return show<void>(
      context,
      title: title,
      body: body ?? Text(message!),
      barrierDismissible: barrierDismissible,
      actions: [
        TvAlertAction(
          label: okLabel ?? context.l10n.ok,
          primary: true,
          autofocus: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  /// Cancel + confirm. Returns `true` only when the user confirms.
  ///
  /// [destructive] lands D-pad on Cancel so a stray OK cannot delete / reset.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String? confirmLabel,
    String? cancelLabel,
    bool destructive = false,
    bool barrierDismissible = true,
  }) async {
    final result = await show<bool>(
      context,
      title: title,
      body: Text(message),
      barrierDismissible: barrierDismissible,
      actions: [
        TvAlertAction(
          label: cancelLabel ?? context.l10n.cancel,
          autofocus: destructive,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
        TvAlertAction(
          label: confirmLabel ?? context.l10n.ok,
          primary: true,
          autofocus: !destructive,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
      ],
    );
    return result == true;
  }
}
