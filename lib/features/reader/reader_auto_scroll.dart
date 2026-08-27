import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Hands-free reading, for the strip and the paged views alike.
///
/// Touching pauses rather than stops, and the rate eases in and out — a first
/// version that hard-stopped on any drag and snapped to full speed felt
/// broken. Speed is a 1-10 feel, not px/s.
class ReaderAutoScroll {
  ReaderAutoScroll({required TickerProvider vsync}) {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;

  /// 1 (slowest) … 10 (fastest).
  double speed = 3;

  /// Continuous-mode rate at each end of the speed scale.
  static const double _minPixelsPerSecond = 15;
  static const double _maxPixelsPerSecond = 260;

  /// Paged-mode dwell per page at each end of the scale.
  static const double _slowestPageSeconds = 14;
  static const double _fastestPageSeconds = 1.5;

  /// Per-frame change in the ease factor — ~0.3s to reach full speed at 60fps,
  /// the same shape Kotatsu uses.
  static const double _easeStep = 0.05;

  /// How long after the finger lifts before it picks up again. Short enough to
  /// feel automatic, long enough that a flick-and-release isn't instantly
  /// fought by the scroller.
  static const Duration _resumeGrace = Duration(milliseconds: 400);

  /// User-facing on/off. Stays true across a pause, which is the whole point:
  /// touching the page doesn't turn the feature off.
  final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  /// True while a finger is down (or during the resume grace).
  final ValueNotifier<bool> paused = ValueNotifier<bool>(false);

  ScrollController? _scroll;
  VoidCallback? _advancePage;

  Duration _last = Duration.zero;
  double _carry = 0; // sub-pixel remainder, else slow speeds drift slower
  double _ease = 0; // 0..1
  double _pageClock = 0; // seconds accumulated toward the next page turn
  int? _resumeToken;

  double get _pixelsPerSecond =>
      _minPixelsPerSecond +
      ((speed.clamp(1, 10) - 1) / 9) *
          (_maxPixelsPerSecond - _minPixelsPerSecond);

  double get _secondsPerPage =>
      _slowestPageSeconds -
      ((speed.clamp(1, 10) - 1) / 9) *
          (_slowestPageSeconds - _fastestPageSeconds);

  /// Continuous mode: creep [controller]. Paged mode: pass [advancePage]
  /// instead and it turns a page every so often.
  void start({ScrollController? controller, VoidCallback? advancePage}) {
    _scroll = controller;
    _advancePage = advancePage;
    _last = Duration.zero;
    _carry = 0;
    _pageClock = 0;
    _ease = 0; // always ramp up, even when resuming
    paused.value = false;
    if (!_ticker.isActive) _ticker.start();
    running.value = true;
  }

  void stop() {
    if (_ticker.isActive) _ticker.stop();
    _scroll = null;
    _advancePage = null;
    _resumeToken = null;
    paused.value = false;
    running.value = false;
  }

  /// Finger down. Keeps [running] true so the chrome still reads as "on".
  void pauseForTouch() {
    if (!running.value) return;
    _resumeToken = null; // cancel any pending resume
    paused.value = true;
  }

  /// Finger up — resume after the grace period, unless something stopped or
  /// re-paused it in the meantime.
  void resumeAfterTouch() {
    if (!running.value) return;
    final token = DateTime.now().microsecondsSinceEpoch;
    _resumeToken = token;
    Future<void>.delayed(_resumeGrace, () {
      if (_resumeToken == token && running.value) paused.value = false;
    });
  }

  void _onTick(Duration elapsed) {
    if (_last == Duration.zero) {
      _last = elapsed;
      return;
    }
    // Clamp: a resumed app or a GC pause would otherwise jump half a chapter.
    final dt = ((elapsed - _last).inMicroseconds / 1000000.0).clamp(0.0, 0.05);
    _last = elapsed;

    // Ease toward the target rate instead of switching instantly.
    final target = paused.value ? 0.0 : 1.0;
    if (_ease < target) {
      _ease = (_ease + _easeStep).clamp(0.0, 1.0);
    } else if (_ease > target) {
      _ease = (_ease - _easeStep).clamp(0.0, 1.0);
    }
    if (_ease == 0) {
      // Fully stopped (paused). Hold the page-turn clock so resuming doesn't
      // immediately flip a page you were mid-way through.
      _pageClock = 0;
      return;
    }

    final advance = _advancePage;
    if (advance != null) {
      _pageClock += dt * _ease;
      if (_pageClock >= _secondsPerPage) {
        _pageClock = 0;
        advance();
      }
      return;
    }

    final c = _scroll;
    if (c == null || !c.hasClients) {
      stop();
      return;
    }
    final step = _pixelsPerSecond * _ease * dt + _carry;
    final whole = step.floorToDouble();
    _carry = step - whole;
    if (whole <= 0) return;

    final max = c.position.maxScrollExtent;
    final next = c.offset + whole;
    if (next >= max) {
      c.jumpTo(max);
      stop(); // end of chapter — the reader decides what happens next
      return;
    }
    c.jumpTo(next);
  }

  void dispose() {
    _ticker.dispose();
    running.dispose();
    paused.dispose();
  }
}
