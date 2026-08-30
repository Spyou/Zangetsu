import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'reader_chrome.dart';
import '../../l10n/l10n.dart';

/// Pull past the end of a chapter to open the next one, with the pull shown
/// as progress.
///
/// Fires on release, not on crossing the line, so you can pull too far and
/// scroll back without anything happening. Wraps a scrollable, so the strip,
/// the paged view and the novel reader all share it.
class ReaderPullChapter extends StatefulWidget {
  const ReaderPullChapter({
    super.key,
    required this.child,
    required this.enabled,
    required this.hasPrev,
    required this.hasNext,
    required this.onChangeChapter,
    this.prevLabel,
    this.nextLabel,
  });

  final Widget child;
  final bool enabled;
  final bool hasPrev;
  final bool hasNext;

  /// -1 for previous, +1 for next.
  final void Function(int delta) onChangeChapter;

  /// Shown on the indicator, e.g. "Chapter 9". Falls back to a generic label.
  final String? prevLabel;
  final String? nextLabel;

  @override
  State<ReaderPullChapter> createState() => _ReaderPullChapterState();
}

class _ReaderPullChapterState extends State<ReaderPullChapter> {
  /// Signed accumulated pull in logical pixels: negative past the start,
  /// positive past the end. Rebuilds the indicator, so it's real state rather
  /// than a bare field.
  double _pull = 0;

  /// True once this gesture has crossed the trigger point — used to fire the
  /// haptic exactly once per pull instead of on every delta past it.
  bool _armed = false;

  /// How far past the edge counts as deliberate.
  static const double _trigger = 110;

  /// Clearance from each edge, measured against the chrome that lives there:
  /// the top pill row (16 inset + 50 tall) and, at the bottom, the taller of
  /// the bottom pill (12 + 50) and the context.l10n.nextChapter2 overlay (24 + ~48).
  static const double _kTopInset = 82;
  static const double _kBottomInset = 96;

  double get _progress => (_pull.abs() / _trigger).clamp(0.0, 1.0);
  bool get _pullingBack => _pull < 0;

  bool get _allowed => _pullingBack ? widget.hasPrev : widget.hasNext;

  void _reset() {
    if (_pull != 0 || _armed) {
      setState(() {
        _pull = 0;
        _armed = false;
      });
    }
  }

  bool _onNotification(ScrollNotification n) {
    if (!widget.enabled) return false;

    if (n is ScrollStartNotification) {
      _reset();
      return false;
    }

    // Overscroll only fires while you're pushing against the edge, so a
    // reversal shows up here instead. Without this the pull kept its peak
    // value and scrolling back still changed chapter.
    if (n is ScrollUpdateNotification) {
      final d = n.scrollDelta ?? 0;
      if (d == 0) return false;
      final movingBack = (_pull > 0 && d < 0) || (_pull < 0 && d > 0);
      if (!movingBack) return false;
      // Wind back down with the finger rather than snapping away. Clamped at
      // zero so one long drag can't run through into the other direction.
      setState(() {
        final next = _pull + d;
        _pull = _pull > 0
            ? next.clamp(0.0, double.infinity)
            : next.clamp(double.negativeInfinity, 0.0);
        if (_armed && _progress < 1) _armed = false;
      });
      return false;
    }

    if (n is OverscrollNotification) {
      // dragDetails == null means a ballistic overscroll — the tail of a fling
      // hitting the edge, not a finger pulling. Counting those would let a
      // hard flick to the end skip a chapter on its own.
      if (n.dragDetails == null) return false;
      setState(() => _pull += n.overscroll);
      if (!_armed && _progress >= 1 && _allowed) {
        _armed = true;
        HapticFeedback.mediumImpact();
      } else if (_armed && _progress < 1) {
        _armed = false;
      }
      return false;
    }

    if (n is ScrollEndNotification) {
      final fire = _progress >= 1 && _allowed;
      final delta = _pullingBack ? -1 : 1;
      _reset();
      if (fire) widget.onChangeChapter(delta);
      return false;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final showing = _pull != 0 && _allowed;
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          // IgnorePointer so the scrollable underneath still gets the drag.
          // Inset clears the chrome: the context.l10n.nextChapter overlay sits at
          // bottom:24 and shows at the same moment this does, so they'd stack.
          if (showing)
            Positioned(
              left: 0,
              right: 0,
              top: _pullingBack ? _kTopInset : null,
              bottom: _pullingBack ? null : _kBottomInset,
              child: SafeArea(
                top: _pullingBack,
                bottom: !_pullingBack,
                child: IgnorePointer(
                  child: Center(
                    child: _PullIndicator(
                      progress: _progress,
                      armed: _armed,
                      pullingBack: _pullingBack,
                      label: _pullingBack
                          ? (widget.prevLabel ?? context.l10n.previousChapter)
                          : (widget.nextLabel ?? context.l10n.nextChapter),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PullIndicator extends StatelessWidget {
  const _PullIndicator({
    required this.progress,
    required this.armed,
    required this.pullingBack,
    required this.label,
  });

  final double progress;
  final bool armed;
  final bool pullingBack;
  final String label;

  @override
  Widget build(BuildContext context) {
    // Fades in over the first fifth, or a stray drag flashes it.
    final opacity = (progress * 5).clamp(0.0, 1.0);
    return Opacity(
      opacity: opacity,
      // Compact: the ring and the arrow-to-tick already say "keep pulling" /
      // "let go", so the only words needed are where you're heading.
      child: ReaderPillSurface(
        radius: 18,
        padding: const EdgeInsets.fromLTRB(7, 6, 12, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 2.2,
                    backgroundColor: Colors.white24,
                    valueColor: AlwaysStoppedAnimation(
                      armed ? AppColors.accent : Colors.white70,
                    ),
                  ),
                  Icon(
                    armed
                        ? Icons.check_rounded
                        : (pullingBack
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded),
                    size: 12,
                    color: armed ? AppColors.accent : Colors.white70,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Capped so a long chapter title can't stretch this back into the
            // wide box it replaced.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.4,
              ),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: armed ? AppColors.accent : Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
