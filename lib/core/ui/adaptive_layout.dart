import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../app_mode.dart';
import '../di/injector.dart';

/// Wide-screen helpers. Everything here is a no-op below [kTabletShortestSide],
/// so a phone gets the exact widgets, sizes and numbers it always had.
const double kTabletShortestSide = 600;

/// Readable width for text-heavy pages (Detail) on a tablet.
const double kTabletContentWidth = 640;

/// True on tablets and unfolded foldables. Uses the SHORT side so a phone
/// turned sideways never counts as a tablet.
bool isTabletLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >= kTabletShortestSide &&
    // A TV has its own D-pad UI; a 1080p box must never pick up tablet sizing.
    !(sl.isRegistered<AppMode>() && sl<AppMode>().isTv);

/// Wide enough for a two-pane page (a 10" tablet, or any tablet sideways).
const double kTabletWideWidth = 840;

bool isWideTabletLayout(BuildContext context) =>
    isTabletLayout(context) &&
    MediaQuery.sizeOf(context).width >= kTabletWideWidth;

/// Content width of a wide-tablet page, centred; the gutter inside it is 32.
const double kWideContentWidth = 1040;

/// Where a wide-tablet page's left edge sits (centred column + 32 gutter), so
/// the title, buttons, tabs and content all line up on one edge.
double wideSideInset(BuildContext context) =>
    math.max(0.0, (MediaQuery.sizeOf(context).width - kWideContentWidth) / 2) +
    32;

/// Centres [child] in a readable column on a tablet; returns [child] itself,
/// untouched, on a phone.
Widget tabletColumn(
  BuildContext context,
  Widget child, {
  double maxWidth = kTabletContentWidth,
}) {
  if (!isTabletLayout(context)) return child;
  return Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}
