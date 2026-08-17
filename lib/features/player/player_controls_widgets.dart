// Skip pills, round buttons, the bar capsule and the centre transport discs.
part of 'player_screen.dart';

class _SkipButton extends StatefulWidget {
  const _SkipButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  State<_SkipButton> createState() => _SkipButtonState();
}

class _SkipButtonState extends State<_SkipButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 340),
  )..forward();
  bool _pressed = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.45),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic)),
        child: AnimatedScale(
          scale: _pressed ? 0.94 : 1,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: Material(
            color: Colors.black.withValues(alpha: 0.38),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: Colors.white.withValues(alpha: 0.6),
                width: 1.2,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapCancel: () => setState(() => _pressed = false),
              onTapUp: (_) => setState(() => _pressed = false),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                child: Text(
                  widget.label,
                  style: AppText.body.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// MegaSkip — Aniyomi-style manual "jump forward N seconds" pill. A compact,
// accent-outlined stadium that sits right-aligned just above the seek bar (so
// it never overlaps the bar or the controls), distinct from the AniSkip pill.
class _MegaSkipPill extends StatelessWidget {
  const _MegaSkipPill({required this.seconds, required this.onTap});
  final int seconds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Deliberately the twin of the timestamp chip it now sits beside — same
    // fill, radius and type. The accent-outlined stadium it used to be was
    // louder than anything else on the bar and read as a stray element.
    // No tooltip: "+85s" already says what it does.
    return Material(
      color: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(13),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.keyboard_double_arrow_right_rounded,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 5),
              Text(
                '+${seconds}s',
                style: AppText.caption.copyWith(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                  letterSpacing: 0.3,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Small circular icon button (used for the unlock control while locked).
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.semanticLabel,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return _withTooltip(
      semanticLabel,
      Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
      ),
    );
  }
}

/// Long-press tooltip for the player's icon-only controls. Most of them lost
/// their text labels to keep the bars compact, so the tooltip is the only way
/// to find out what one does without pressing it.
///
/// Semantics are excluded by default because these buttons already declare
/// their own — letting the tooltip add a second label makes a screen reader
/// announce everything twice. Pass false for a control that has none.
Widget _withTooltip(
  String? message,
  Widget child, {
  bool excludeSemantics = true,
}) {
  if (message == null || message.isEmpty) return child;
  return Tooltip(
    message: message,
    excludeFromSemantics: excludeSemantics,
    child: child,
  );
}

/// Aspect-mode icon. The fit button dropped its text label to keep every
/// button the same width, so the icon has to carry which mode you're on.
IconData _fitIcon(String label) => switch (label) {
  'Fill' => Icons.crop_free_rounded,
  'Stretch' => Icons.open_in_full_rounded,
  _ => Icons.fit_screen_rounded,
};

/// One translucent capsule holding a set of [_BarButton]s. Grouping them means
/// a single soft backdrop behind the row instead of a chip per icon, which is
/// quieter over video — plain alpha, no BackdropFilter, so it costs nothing to
/// composite. It's also the Material the buttons' ripples paint onto; without
/// it they'd splash on the Scaffold underneath and be hidden by this backdrop.
class _BarGroup extends StatelessWidget {
  const _BarGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(26),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A single icon button inside a [_BarGroup] — uniform square footprint so the
/// row never reflows, transparent itself since the group carries the backdrop.
class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return _withTooltip(
      tooltip,
      Semantics(
        button: true,
        label: tooltip,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }
}

/// A single leading-icon row in the ⋮ More overflow sheet.
class _MoreRow extends StatelessWidget {
  const _MoreRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            // Tighter than the old 14 — the panel is narrower now, and these
            // rows were spaced like a settings screen rather than a menu.
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Row(
              children: [
                Icon(icon, color: AppColors.textPrimary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: AppText.body.copyWith(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Strips a leading episode marker from [title] when it just repeats [n].
///
/// Plenty of sources hand back "Episode 2: I Suppose You Aren't Aware", which
/// sits next to the "E2" the panel already draws and eats the whole line for
/// something you can see a centimetre to the left.
///
/// Two shapes, deliberately narrow:
///  * a word form — "Episode 2 …", "Ep.2 - …", "E2: …" — separator optional;
///  * a bare number — "2. …", "02 - …" — where the separator is REQUIRED,
///    otherwise a title like "12 Monkeys" on episode 12 would lose its name.
class _AnimatedPlayPause extends StatelessWidget {
  const _AnimatedPlayPause({required this.playing, required this.onTap});
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // No tooltip — play/pause needs no explaining, and a bubble over the
    // middle of the picture is just in the way.
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      // Larger disc than the episode arrows so the row keeps its hierarchy —
      // the icon inside is bigger too, so matching discs would have crowded
      // this one while leaving the arrows swimming in theirs.
      child: _TransportDisc(
        size: 58,
        onTap: onTap,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.72, end: 1).animate(anim),
              child: child,
            ),
          ),
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            key: ValueKey<bool>(playing),
            color: Colors.white,
            size: 34,
          ),
        ),
      ),
    );
  }
}

/// Backdrop for the three centre transport buttons. They sit over the middle
/// of the picture where barely any scrim reaches, so they carry more alpha
/// than the bottom capsules' 0.3 — at that level they wash out on a bright
/// frame. [dimmed] fades the disc along with its icon, otherwise a dead arrow
/// ends up inside a solid circle and reads as broken rather than unavailable.
class _TransportDisc extends StatelessWidget {
  const _TransportDisc({
    required this.size,
    required this.child,
    required this.onTap,
    this.dimmed = false,
  });

  final double size;
  final Widget child;
  final VoidCallback? onTap;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    // The disc is itself the Material the ripple paints onto. A plain
    // DecoratedBox wouldn't do: ink splashes render on the nearest Material
    // ancestor, which would be the Scaffold underneath — so the ripple would
    // spread behind this circle and never be seen. Clipping to the same
    // CircleBorder keeps the splash inside the disc instead of squaring off.
    return Material(
      color: Colors.black.withValues(alpha: dimmed ? 0.18 : 0.45),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        // Explicit, because the theme's default splash is tuned for opaque
        // surfaces and barely shows on a translucent black disc over video.
        splashColor: Colors.white.withValues(alpha: 0.22),
        highlightColor: Colors.white.withValues(alpha: 0.10),
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: child),
        ),
      ),
    );
  }
}

/// Episode step either side of play/pause. A null [onTap] means there's
/// nowhere to step (first or last episode): the button dims and stops taking
/// touches, so the tap falls through and toggles the controls like any other
/// empty patch of screen rather than dying on a dead button. It stays mounted
/// either way, which is what keeps play/pause centred instead of sliding as
/// the row shrinks.
///
/// No tooltip: the three transport controls are the most self-evident thing on
/// the screen, so a bubble over them is noise. The bottom bar keeps its
/// tooltips — those buttons lost their text labels and need the help.
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: IgnorePointer(
        ignoring: !enabled,
        child: _TransportDisc(
          size: 46,
          dimmed: !enabled,
          onTap: onTap,
          child: Icon(
            icon,
            color: Colors.white.withValues(alpha: enabled ? 1 : 0.28),
            size: 26,
          ),
        ),
      ),
    );
  }
}

/// The player's bottom-sheet surface: a SOLID, detached card that floats above
/// the screen edges (margins + full-radius + soft shadow), centred in landscape
/// — instead of an edge-to-edge frosted panel. Drop-in for the old
/// `FrostedSurface(...)` sheet wrappers: it accepts (and ignores) blur/opacity/
/// borderRadius so those call sites only needed a rename.
