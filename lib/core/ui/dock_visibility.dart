import 'package:flutter/widgets.dart';

/// Bottom offset for an overlay positioned from the SCREEN edge — the root
/// shell's "press back again" toast — so it floats above the dock. Includes a
/// typical system inset, because an overlay gets no inset of its own.
///
/// NOT for scrollable tabs. The dock is the shell's `bottomNavigationBar` and
/// the shell sets `extendBody: true`, so Flutter already folds the dock's full
/// height into the body's `MediaQuery.padding.bottom`. Adding this on top of
/// that counted the whole dock twice and left a dead band under the last row
/// on every tab. Scrollables want the MediaQuery bottom inset alone.
const double kDockClearance = 104.0;

/// True while an in-tab sub-page wants the shell's floating dock hidden — set
/// by the Settings screen when you drill into a section. The shell also gates
/// on the active tab, so this only hides the dock while that tab is showing.
final ValueNotifier<bool> dockHiddenBySection = ValueNotifier<bool>(false);

/// True while an in-tab handler owns the next Back press — e.g. an open Settings
/// section (backs out to the categories) or an active Settings search (clears).
/// Those handlers live in the SAME route as the shell's double-back PopScope, so
/// Flutter fires the shell's callback too; the shell checks this to stand down
/// and not flash "Press BACK again to exit" over a normal in-tab back-out.
final ValueNotifier<bool> shellBackIntercepted = ValueNotifier<bool>(false);

/// True while the dock is collapsed to icons — labels faded out and the pill
/// pulled in — because the page underneath is being scrolled down.
///
/// Deliberately NOT a hide. The tabs stay on screen and stay tappable; only
/// the labels and the pill's width give way, so browsing a long list gets a
/// little more room without putting navigation behind a scroll-up first.
final ValueNotifier<bool> dockCollapsedByScroll = ValueNotifier<bool>(false);

/// Turns a tab's vertical scrolling into [dockCollapsedByScroll].
///
/// Wired once, at the shell, around the whole tab body — so every tab feeds it
/// and no screen has to opt in or know the dock exists.
class DockScrollCollapse {
  const DockScrollCollapse._();

  /// How far you have to keep going one way before the dock reacts. Small
  /// enough to feel immediate, large enough that a thumb settling on the glass
  /// doesn't flip it.
  static const double threshold = 60;

  static double _acc = 0;

  /// Feed a [ScrollNotification]. Always returns false — this observes the
  /// scroll, it never consumes it.
  static bool onNotification(ScrollNotification n) {
    // Home's poster rails scroll horizontally inside the vertical page, and
    // their notifications bubble to the same listener. Flicking a rail is not
    // a reason to change the dock.
    if (n.metrics.axis != Axis.vertical) return false;
    if (n is! ScrollUpdateNotification) return false;
    final d = n.scrollDelta ?? 0;
    if (d == 0) return false;

    // At rest near the top the dock is always whole — otherwise a page that
    // ends mid-scroll leaves it collapsed with nothing left to scroll.
    if (n.metrics.pixels <= 8) {
      _acc = 0;
      dockCollapsedByScroll.value = false;
      return false;
    }

    // A change of direction restarts the count, so the threshold measures a
    // deliberate move rather than the sum of a jittery one.
    if ((d > 0 && _acc < 0) || (d < 0 && _acc > 0)) _acc = 0;
    _acc += d;

    if (_acc > threshold && !dockCollapsedByScroll.value) {
      dockCollapsedByScroll.value = true;
      _acc = 0;
    } else if (_acc < -threshold && dockCollapsedByScroll.value) {
      dockCollapsedByScroll.value = false;
      _acc = 0;
    }
    return false;
  }

  /// Back to whole, counter cleared — on a tab switch, where the new tab's
  /// scroll position has nothing to do with the one you left.
  static void reset() {
    _acc = 0;
    dockCollapsedByScroll.value = false;
  }
}
