import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'tv_focusable.dart';

/// A D-pad-focusable Back button for TV screens that have no navigation rail.
///
/// Wrap the screen body in a [Stack] and overlay this with [Positioned] at the
/// top-left so the user can navigate back with the OK key as well as the remote
/// Back button:
///
/// ```dart
/// body: Stack(
///   children: [
///     SafeArea(child: <content>),
///     const Positioned(top: 8, left: 8, child: SafeArea(child: TvBackButton())),
///   ],
/// ),
/// ```
///
/// [autofocus] defaults to false — the primary action on the screen (e.g. the
/// Play button on Detail) should keep its autofocus; the Back button is
/// reachable via D-pad up/left.
class TvBackButton extends StatelessWidget {
  const TvBackButton({super.key, this.autofocus = false});

  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      onTap: () => Navigator.of(context).maybePop(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.arrow_back_rounded,
              color: AppColors.textPrimary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(
              'Back',
              style: AppText.body.copyWith(color: AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
