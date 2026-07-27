import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/manga_seal/switch_sound.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'manga_seal_screen.dart';

/// The permanent "Manga" entry in the Home feed. Its centrepiece is a
/// slide-to-reveal switch: sliding it plays the release SFX and opens the
/// coming-soon screen, then snaps back. When Manga ships, the same card drops
/// the "Coming soon" label and the switch opens the library instead.
class MangaSealCard extends StatefulWidget {
  const MangaSealCard({super.key});

  @override
  State<MangaSealCard> createState() => _MangaSealCardState();
}

class _MangaSealCardState extends State<MangaSealCard> {
  bool _busy = false;

  Future<void> _open() async {
    if (_busy) return;
    _busy = true;
    HapticFeedback.mediumImpact();
    SwitchSound.play(); // fire-and-forget; silent until the clip is hosted
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) => const MangaSealScreen(),
        transitionsBuilder: (_, anim, _, child) => FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0).animate(
              CurvedAnimation(parent: anim, curve: Curves.easeOut),
            ),
            child: child,
          ),
        ),
      ),
    );
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Manga', style: AppText.headline),
                const Spacer(),
                Text(
                  'Coming soon',
                  style: AppText.caption.copyWith(color: accent),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text('Read manga & webtoons', style: AppText.caption),
            const SizedBox(height: 14),
            _SlideToReveal(accent: accent, onRevealed: _open),
          ],
        ),
      ),
    );
  }
}

/// A drag-across switch. The knob follows your finger; past ~80% (or a plain
/// tap) it fires [onRevealed] and then snaps home.
class _SlideToReveal extends StatefulWidget {
  const _SlideToReveal({required this.accent, required this.onRevealed});

  final Color accent;
  final Future<void> Function() onRevealed;

  @override
  State<_SlideToReveal> createState() => _SlideToRevealState();
}

class _SlideToRevealState extends State<_SlideToReveal>
    with SingleTickerProviderStateMixin {
  static const double _h = 52;
  static const double _knob = 44;
  static const double _pad = 4;

  double _frac = 0; // 0 = home, 1 = fully slid
  bool _fired = false;

  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  void _snapHome() {
    final from = _frac;
    _snap.reset();
    void tick() => setState(() => _frac = from * (1 - _snap.value));
    _snap
      ..addListener(tick)
      ..forward().whenComplete(() => _snap.removeListener(tick));
  }

  Future<void> _fire() async {
    if (_fired) return;
    _fired = true;
    setState(() => _frac = 1);
    await widget.onRevealed();
    if (mounted) setState(() => _frac = 0);
    _fired = false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final maxX = c.maxWidth - _knob - _pad * 2;
        final x = _pad + _frac * maxX;
        return GestureDetector(
          onTap: _fire,
          onHorizontalDragUpdate: (d) {
            if (_fired) return;
            setState(
              () => _frac = (_frac + d.delta.dx / maxX).clamp(0.0, 1.0),
            );
          },
          onHorizontalDragEnd: (_) {
            if (_fired) return;
            if (_frac >= 0.8) {
              _fire();
            } else {
              _snapHome();
            }
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_h / 2),
            child: Container(
              height: _h,
              decoration: BoxDecoration(
                color: AppColors.surface2,
                border: Border.all(color: AppColors.hairline),
                borderRadius: BorderRadius.circular(_h / 2),
              ),
              child: Stack(
                children: [
                  // Accent trail behind the knob.
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: x + _knob + _pad,
                      color: widget.accent.withValues(alpha: 0.18),
                    ),
                  ),
                  // Hint, fading out as you slide.
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(left: _knob * 0.5),
                      child: Opacity(
                        opacity: (1 - _frac * 1.6).clamp(0.0, 1.0),
                        child: Text(
                          'Slide to reveal  ›››',
                          style: AppText.caption.copyWith(
                            color: AppColors.textSecondary,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Knob.
                  Positioned(
                    left: x,
                    top: _pad,
                    child: Container(
                      width: _knob,
                      height: _knob,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            widget.accent,
                            widget.accent.withValues(alpha: 0.75),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: widget.accent.withValues(alpha: 0.45),
                            blurRadius: 12,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.chevron_right,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
