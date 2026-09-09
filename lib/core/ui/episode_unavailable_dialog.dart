import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import '../models/episode.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../tv/tv_focusable.dart';

/// Shown when the catalogue lists an episode that the ONE matched source does
/// not have. Returns true when the viewer wants every other installed source
/// checked anyway.
///
/// The row is never a dead end. We only ever asked one source — naming it is
/// the only honest thing we can say — so the sweep stays available on request
/// rather than being forced on everyone who taps the last episode of an airing
/// show. That sweep is what measured 23 seconds of frozen UI, and it is now
/// bounded (8s per source, failures skipped, the result remembered), so asking
/// for it deliberately is a fair trade.
Future<bool> showEpisodeUnavailable(
  BuildContext context,
  Episode ep, {
  /// True for manga/novel, so the wording says chapter.
  bool reading = false,
}) async {
  final what = reading ? 'chapter' : 'episode';
  final n = ep.number?.toInt();
  final reason = ep.unavailable ?? 'Not available';
  final out = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.hourglass_empty_rounded,
                color: AppColors.accent,
                size: 30,
              ),
            ),
            const SizedBox(height: 18),
            Text(reason, style: AppText.headline, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(
              n == null
                  ? "Only one source has been checked for this $what. The rest "
                        'can be searched now if you want.'
                  : "Only one source has been checked for $what $n. The rest "
                        'can be searched now if you want.',
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            _DeadEndButton(
              icon: Icons.travel_explore_rounded,
              label: 'Check other sources',
              filled: true,
              onTap: () => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 10),
            _DeadEndButton(
              icon: Icons.close_rounded,
              label: 'Not now',
              filled: false,
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    ),
  );
  return out ?? false;
}

/// Shown when the player resolved everything it could and NOTHING ever played.
///
/// Returns true when the viewer wants another go; false (or dismissal) means
/// hand them back where they came from. The player calls this instead of
/// leaving them sitting on a black screen with an error — a dead end you have
/// to press Back on reads like a crash, and the answer belongs where they can
/// act on it: pick another episode, another source, or try again.
///
/// Only for the never-played case. Playback that dies PARTWAY keeps the
/// in-place error and its Try again, because the viewer is already watching
/// something and yanking them out would lose their place.
Future<bool> showPlaybackDeadEnd(BuildContext context, String message) async {
  // The controller keeps headline and detail as one string (see PlayerState) —
  // same split the in-player error does.
  final lines = message.split('\n');
  final headline = lines.first;
  final detail = lines.skip(1).join('\n');
  final out = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.error_outline_rounded,
                color: AppColors.accent,
                size: 30,
              ),
            ),
            const SizedBox(height: 18),
            Text(headline, style: AppText.headline, textAlign: TextAlign.center),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(detail, style: AppText.caption, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 22),
            _DeadEndButton(
              icon: Icons.refresh_rounded,
              label: 'Try again',
              filled: true,
              onTap: () => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 10),
            _DeadEndButton(
              icon: Icons.arrow_back_rounded,
              label: 'Go back',
              filled: false,
              onTap: () => Navigator.pop(ctx, false),
            ),
          ],
        ),
      ),
    ),
  );
  return out ?? false;
}

class _DeadEndButton extends StatelessWidget {
  const _DeadEndButton({
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.black : AppColors.accent;
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 10),
          Text(label, style: AppText.headline.copyWith(color: fg, fontSize: 16)),
        ],
      ),
    );
    // On TV a plain InkWell IS reachable by D-pad but draws no highlight, so
    // you cannot see which button you are on. TvFocusable is the app's own
    // focus treatment; on a phone `isTv` is always false and this stays the
    // InkWell it was.
    final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: filled ? AppColors.accent : AppColors.accentSoft,
        borderRadius: BorderRadius.circular(30),
        clipBehavior: Clip.antiAlias,
        child: isTv
            ? TvFocusable(
                variant: TvFocusVariant.pill,
                scale: 1.0,
                // The primary action takes focus, so a remote can act on the
                // dialog without hunting for where it landed.
                autofocus: filled,
                semanticLabel: label,
                onTap: onTap,
                child: body,
              )
            : InkWell(onTap: onTap, child: body),
      ),
    );
  }
}
