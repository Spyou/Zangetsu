import 'dart:async';

import 'package:visibility_detector/visibility_detector.dart';

/// Runs before every test in the package (Flutter picks this file up by name).
///
/// `RevealItem` wraps list/grid cards in a `VisibilityDetector` so the entrance
/// animation fires when a card is actually on screen. The detector batches its
/// callbacks behind a timer — 500ms by default — and a widget test fails if a
/// timer is still pending when it ends, so any test that renders a list would
/// otherwise die with "Pending timers" through no fault of its own.
///
/// Zero makes the callbacks synchronous and schedules no timer. The app sets
/// its own interval in main.dart; this only affects tests.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  await testMain();
}
