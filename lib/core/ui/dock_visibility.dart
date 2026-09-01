import 'package:flutter/foundation.dart';

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
