import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'reader_chrome.dart';

/// Pull past the end of a chapter to open the next one — with the pull itself
/// shown as progress, so you can see it coming, see how much further to go,
/// and back out.
///
/// Fires on RELEASE, not on crossing the threshold. That's the whole point of
/// showing progress: an instant trigger mid-drag gives you no chance to change
/// your mind, and the indicator would flash past too fast to read. Pull too
/// far by accident, scroll back, nothing happens.
///
/// Wraps a scrollable rather than living inside it, so the manga strip, the
/// paged view and the novel reader all share one implementation.
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
  /// the bottom pill (12 + 50) and the "Next chapter →" overlay (24 + ~48).
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

    // Dragging back into the content cancels the pull.
    //
    // Overscroll deltas only arrive while the edge is actually being pushed
    // against, so reversing produces ordinary scroll updates and nothing else.
    // Without this the accumulated pull kept its peak value all the way to
    // release, and pulling past the line then scrolling back still changed
    // chapter — the exact opposite of what the progress ring is promising.
    if (n is ScrollUpdateNotification) {
      final d = n.scrollDelta ?? 0;
      if (d == 0) return false;
      final movingBack = (_pull > 0 && d < 0) || (_pull < 0 && d > 0);
      if (!movingBack) return false;
      // Wind the ring back DOWN with the finger rather than snapping it away:
      // the whole point of showing progress is that it tracks the gesture, and
      // a ring that vanishes the instant you reverse tells you nothing about
      // how far back you've come. Clamped at zero so it can't run through into
      // the opposite direction on one long drag.
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
          // IgnorePointer: the indicator sits over the page mid-drag and must
          // never take the pointer away from the scrollable underneath.
          //
          // Inset well clear of the chrome at each edge. The bottom especially:
          // the reader's own "Next chapter →" overlay sits at bottom:24, and
          // this appears at exactly the moment that button does (end of the
          // chapter) — at the same offset the two stack and neither is
          // readable. Above the bottom pill and that button; below the top pills.
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
                          ? (widget.prevLabel ?? 'Previous chapter')
                          : (widget.nextLabel ?? 'Next chapter'),
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
    // Fades in over the first fifth of the pull rather than appearing at full
    // strength on the first pixel, which reads as a flicker on a stray drag.
    final opacity = (progress * 5).clamp(0.0, 1.0);
    return Opacity(
      opacity: opacity,
      // Compact on purpose: this floats over the page mid-gesture, so it should
      // read at a glance and cover as little art as possible. The ring's fill
      // and the arrow-to-tick flip already say "keep pulling" / "let go", so
      // the only words needed are which chapter you're heading to.
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
