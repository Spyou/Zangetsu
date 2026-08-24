import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../di/injector.dart';
import '../playback/playback_prefs.dart';

/// What to do when someone opens something other than where they left off.
enum JumpChoice {
  /// Read/watch it without touching saved progress — no resume mark, no
  /// Continue card, nothing sent to the trackers.
  peek,

  /// Treat this as the new place: progress saves here as normal.
  move,
}

/// Whether opening [targetIndex] counts as a jump worth asking about.
///
/// [resumeIndex] is where the title would naturally continue — the chapter or
/// episode the Resume button points at — so opening exactly that is just
/// carrying on and never prompts. Everything else is a jump, in either
/// direction: forward skips past unread items, and backwards would otherwise
/// drag the tracker count DOWN to whatever was re-opened, since progress is
/// pushed as an absolute number rather than a maximum.
///
/// Never asks when there's nothing to protect ([hasResume] false — a title
/// opened for the first time), and never when the user has turned the prompt
/// off.
bool shouldAskBeforeJump({
  required int resumeIndex,
  required int targetIndex,
  required bool hasResume,
  required bool askEnabled,
}) {
  if (!askEnabled || !hasResume) return false;
  return targetIndex != resumeIndex;
}

/// Reads the preference itself, defensively — widget tests build detail screens
/// without PlaybackPrefs registered, and a prompt is not worth throwing over.
bool get jumpPromptEnabled {
  try {
    return sl<PlaybackPrefs>().askOnJump;
  } catch (_) {
    return false;
  }
}

/// Asks whether to move progress to what's being opened. Null when dismissed,
/// which callers treat as "don't open at all" — a stray tap shouldn't commit
/// to either answer.
Future<JumpChoice?> showJumpPrompt(
  BuildContext context, {
  /// True for manga/novel, so the wording says chapter rather than episode.
  required bool reading,
}) {
  final what = reading ? 'chapter' : 'episode';
  return showDialog<JumpChoice>(
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
                Icons.visibility_outlined,
                color: AppColors.accent,
                size: 30,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Jump to this $what?',
              style: AppText.headline,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              "You left off somewhere else. Take a look without losing your "
              'place, or move your progress here.',
              style: AppText.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 22),
            _JumpButton(
              icon: Icons.visibility_outlined,
              label: 'Just look',
              filled: true,
              onTap: () => Navigator.pop(ctx, JumpChoice.peek),
            ),
            const SizedBox(height: 10),
            _JumpButton(
              icon: Icons.done_all_rounded,
              label: 'Move progress here',
              filled: false,
              onTap: () => Navigator.pop(ctx, JumpChoice.move),
            ),
          ],
        ),
      ),
    ),
  );
}

class _JumpButton extends StatelessWidget {
  const _JumpButton({
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
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: filled ? AppColors.accent : AppColors.accentSoft,
        borderRadius: BorderRadius.circular(30),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 15),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: fg, size: 20),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: AppText.headline.copyWith(color: fg, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
