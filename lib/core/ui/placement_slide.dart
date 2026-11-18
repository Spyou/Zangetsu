import 'package:flutter/material.dart';

/// setState that is safe to call from unmount-phase dispose paths (a delete
/// committing as its card unmounts), where a synchronous setState would throw
/// "widget tree was locked". Runs as a microtask: after the current
/// synchronous unmount walk finishes (so it's legal), but before the next
/// frame paints (so the commit's hide still lands in the same frame as the
/// ash reset — no one-frame poster flash in between).
void safeRebuild(State state) {
  if (!state.mounted) return;
  Future.microtask(() {
    if (state.mounted) {
      // ignore: invalid_use_of_protected_member
      state.setState(() {});
    }
  });
}

/// Visibility rule for optimistically-removed keys. A committed key
/// stays hidden while its commit is in flight or the store no longer has it;
/// a key back in the list with no commit in flight was re-added — show it
/// again at once. Pure so it stays unit-testable; the screens own the sets.
bool libraryKeyVisible({
  required bool commitInFlight,
  required bool presentInStore,
}) => presentInStore && !commitInFlight;

/// A travel ticket for one moved card: glide from [from] to its real spot.
class SlideSpec {
  SlideSpec(this.from, this.unplace, {this.duration = _kSlideDuration});

  /// Offset the card starts at. Always ends at zero — which is the true
  /// position — so a stale slide can never strand a card off-place.
  final Offset from;

  /// Glide duration. Nuvio uses 180ms; 300ms reads smoother on mid-range
  /// phones without feeling laggy.
  final Duration duration;

  /// Drops this slide (called when its glide completes).
  final VoidCallback unplace;
}

const Duration _kSlideDuration = Duration(milliseconds: 300);

/// One-shot glide from [from] to the card's real spot. No opacity anywhere:
/// fades read as appearing/vanishing, this is pure slide.
///
/// Always mounted (even with [Offset.zero]): that keeps the subtree shape
/// identical across rebuilds, so keyed cards never remount their images just
/// because they moved — a remount would replay the image fade-in and read as
/// appearing out of nowhere. A changed non-zero [from] restarts the glide.
class PlacementSlide extends StatefulWidget {
  const PlacementSlide({
    super.key,
    required this.from,
    required this.duration,
    required this.onDone,
    required this.child,
  });

  final Offset from;
  final Duration duration;
  final VoidCallback onDone;
  final Widget child;

  @override
  State<PlacementSlide> createState() => _PlacementSlideState();
}

class _PlacementSlideState extends State<PlacementSlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  /// Last travel armed. Compared in didUpdateWidget so a fresh non-zero travel
  /// restarts the glide while a rebuild with the same one keeps playing.
  late Offset _from = widget.from;

  Animation<Offset> get _offset => _c
      .drive(CurveTween(curve: Curves.easeOutCubic))
      .drive(Tween(begin: _from, end: Offset.zero));

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
    if (_from != Offset.zero) _c.forward();
  }

  @override
  void didUpdateWidget(PlacementSlide old) {
    super.didUpdateWidget(old);
    if (widget.from != Offset.zero && widget.from != _from) {
      _from = widget.from;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) =>
          Transform.translate(offset: _offset.value, child: child),
      child: widget.child,
    );
  }
}
