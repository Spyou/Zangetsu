import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'tv_focusable.dart';

/// A D-pad-focusable Back control. Put it in the layout **above** content
/// ([AppBar] leading, [TvBackHeader], or a header [Row]) — never as a
/// [Positioned] overlay on posters. Overlays sit on the first cell, so D-pad
/// up/left cannot land on them.
class TvBackButton extends StatelessWidget {
  const TvBackButton({super.key, this.autofocus = false});

  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      semanticLabel: 'Back',
      onTap: () => Navigator.of(context).maybePop(),
      // Excluded — semanticLabel above already announces "Back"; without
      // this the nested Text was a second sibling node and TalkBack read
      // it twice.
      child: ExcludeSemantics(
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
      ),
    );
  }
}

/// Header row with [TvBackButton] in document flow so it is reachable with
/// D-pad up from the first content row.
class TvBackHeader extends StatelessWidget {
  const TvBackHeader({super.key, this.title, this.titleWidget, this.trailing});

  final String? title;
  final Widget? titleWidget;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 24, 8),
      child: Row(
        children: [
          const TvBackButton(),
          if (titleWidget != null) ...[
            const SizedBox(width: 16),
            Expanded(child: titleWidget!),
          ] else if (title != null) ...[
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                title!,
                style: AppText.largeTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
