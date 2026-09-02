import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';

/// Single-row Anime ↔ Movie·TV toggle for the TV nav rail (under the profile).
/// OK flips the active streaming catalogue; no separate page.
class TvStreamKindRailToggle extends StatelessWidget {
  const TvStreamKindRailToggle({
    super.key,
    required this.navOpen,
    required this.iconSlotWidth,
    required this.onToggle,
    this.focusNode,
  });

  final bool navOpen;
  final double iconSlotWidth;
  final FocusNode? focusNode;
  final Future<void> Function(StreamKind next) onToggle;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ZModePrefs.revision,
      builder: (context, _, __) {
        final l10n = context.l10n;
        final isAnime = ZModePrefs.streamKind == StreamKind.anime;
        final icon = isAnime ? Icons.play_circle_rounded : Icons.movie;
        final activeLabel = isAnime ? l10n.modeAnime : l10n.modeMovieTv;

        return TvFocusable(
          key: const ValueKey('tv-stream-kind-toggle'),
          focusNode: focusNode,
          variant: TvFocusVariant.pill,
          semanticLabel: activeLabel,
          // KeyUp (not postFrameCallback): a deferred toggle waits for the next
          // frame, and a busy isolate can stall frames for seconds — the tap
          // then appears to hang until the frame pipeline clears.
          waitForKeyUp: true,
          onTap: () {
            final next = isAnime ? StreamKind.movie : StreamKind.anime;
            unawaited(onToggle(next));
          },
          builder: (focused) {
            final activeFg = focused ? Colors.black : AppColors.textPrimary;
            final inactiveFg = focused
                ? Colors.black.withValues(alpha: 0.45)
                : AppColors.textTertiary;
            final iconColor = focused ? Colors.black : AppColors.accent;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: iconSlotWidth,
                    child: Center(
                      child: Icon(icon, color: iconColor, size: 22),
                    ),
                  ),
                  Expanded(
                    child: navOpen
                        ? ExcludeSemantics(
                            child: Row(
                              children: [
                                Text(
                                  l10n.modeAnime,
                                  style: TextStyle(
                                    color: isAnime ? activeFg : inactiveFg,
                                    fontSize: 15,
                                    fontWeight: isAnime
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: Text(
                                    '|',
                                    style: TextStyle(
                                      color: focused
                                          ? Colors.black38
                                          : AppColors.textTertiary,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                Flexible(
                                  child: Text(
                                    l10n.modeMovieTv,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isAnime ? inactiveFg : activeFg,
                                      fontSize: 15,
                                      fontWeight: isAnime
                                          ? FontWeight.w500
                                          : FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (navOpen) const SizedBox(width: 12),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
