import 'package:flutter/foundation.dart';

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
