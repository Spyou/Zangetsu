import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_keys.dart';

/// TV D-pad controls overlay for the video player.
///
/// Replaces both the phone gesture surface (item 2) and the
/// [_ControlsOverlay] (item 6) in the player Stack when
/// [AppMode.isTv] is true. All playback logic stays in
/// [PlayerCubit] — this widget only drives INPUT.
///
/// Bar visibility is parent-controlled via [barVisible] + [onBarChange]
/// so the parent [_PlayerScreenState] can gate its [PopScope] correctly:
/// the first Back press hides the bar; the second exits the player.
///
/// Auto-hide timer lives here: the bar hides automatically after
/// [_kHideDelay] of idle.
class PlayerTvControls extends StatefulWidget {
  const PlayerTvControls({
    super.key,
    required this.onTogglePlay,
    required this.onSeekBy,
    required this.onSpeed,
    required this.onAudioSubs,
    required this.onQuality,
    required this.onSources,
    required this.onFit,
    required this.onBack,
    this.onNext,
    required this.barVisible,
    required this.onBarChange,
  });

  /// Calls [PlayerCubit.togglePlay].
  final VoidCallback onTogglePlay;

  /// Calls [PlayerCubit.seekBy] with the given delta.
  final void Function(Duration) onSeekBy;

  // Sheet openers — reuse the existing [_PlayerScreenState] handlers verbatim.
  final VoidCallback onSpeed;
  final VoidCallback onAudioSubs;
  final VoidCallback onQuality;
  final VoidCallback onSources;

  /// Cycles the video fit mode ([_PlayerScreenState._cycleFit]).
  final VoidCallback onFit;

  /// Pops the route ([Navigator.of(context).maybePop]).
  final VoidCallback onBack;

  /// Advances to the next episode. Null when there is none.
  final VoidCallback? onNext;

  /// Whether the bottom control bar is currently shown.
  /// Controlled by the parent so [PopScope.canPop] can be wired correctly.
  final bool barVisible;

  /// Notifies the parent of bar visibility changes (show / hide).
  final void Function(bool) onBarChange;

  @override
  State<PlayerTvControls> createState() => _PlayerTvControlsState();
}

/// How long the bar stays visible after the last D-pad interaction.
const Duration _kHideDelay = Duration(seconds: 5);

class _PlayerTvControlsState extends State<PlayerTvControls> {
  Timer? _hideTimer;

  // Scope node for the bottom button row.  Checking [_barScope.hasFocus]
  // tells us whether a button is selected so we know whether arrow-left /
  // arrow-right should seek or traverse the row.
  final FocusScopeNode _barScope = FocusScopeNode();

  // The root Focus node — held so we can request it back when arrowUp is
  // pressed from inside the bar (i.e. move focus out of the bar row).
  late final FocusNode _rootFocus;

  @override
  void initState() {
    super.initState();
    _rootFocus = FocusNode();
    if (widget.barVisible) _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _barScope.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  // ── Bar visibility helpers ─────────────────────────────────────────────────

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_kHideDelay, () {
      if (mounted) widget.onBarChange(false);
    });
  }

  void _showBar() {
    if (!widget.barVisible) widget.onBarChange(true);
    _scheduleHide();
  }

  void _hideBar() {
    _hideTimer?.cancel();
    widget.onBarChange(false);
  }

  // ── D-pad key handler ─────────────────────────────────────────────────────
  //
  // This runs on the ROOT Focus node only; inner TvFocusable nodes handle OK
  // themselves (returning KeyEventResult.handled) so the outer Focus never sees
  // those events when a bar button is selected.

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;

    // ── OK / Select ──
    // Play/pause when focus is outside the bar (bar buttons handle OK themselves).
    if (okKeys.contains(k)) {
      if (!_barScope.hasFocus) widget.onTogglePlay();
      _showBar();
      return KeyEventResult.handled;
    }

    // ── Arrow Right → seek +10 s (pass through when focus is in the bar row) ──
    if (k == LogicalKeyboardKey.arrowRight) {
      if (_barScope.hasFocus) return KeyEventResult.ignored; // bar traversal
      widget.onSeekBy(const Duration(seconds: 10));
      _showBar();
      return KeyEventResult.handled;
    }

    // ── Arrow Left → seek −10 s ──
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (_barScope.hasFocus) return KeyEventResult.ignored; // bar traversal
      widget.onSeekBy(const Duration(seconds: -10));
      _showBar();
      return KeyEventResult.handled;
    }

    // ── Arrow Down → reveal bar; move focus into the bar row ──
    if (k == LogicalKeyboardKey.arrowDown) {
      _showBar();
      if (!_barScope.hasFocus) _barScope.requestFocus();
      return KeyEventResult.handled;
    }

    // ── Arrow Up → reveal bar; move focus out of the bar row ──
    if (k == LogicalKeyboardKey.arrowUp) {
      _showBar();
      if (_barScope.hasFocus) _rootFocus.requestFocus();
      return KeyEventResult.handled;
    }

    // ── Back / Escape ──
    // First press hides the bar; second press exits the player.
    if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
      if (widget.barVisible) {
        _hideBar();
      } else {
        widget.onBack();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Assemble the bottom row buttons.  onNext is omitted when null (no next ep).
    final buttons = <(IconData, String, VoidCallback)>[
      (Icons.speed, 'Speed', widget.onSpeed),
      (Icons.subtitles_rounded, 'Audio & subs', widget.onAudioSubs),
      (Icons.high_quality, 'Quality', widget.onQuality),
      (Icons.video_settings, 'Sources', widget.onSources),
      (Icons.aspect_ratio_rounded, 'Fit', widget.onFit),
      if (widget.onNext != null) (Icons.skip_next, 'Next', widget.onNext!),
    ];

    return Focus(
      focusNode: _rootFocus,
      autofocus: true,
      onKeyEvent: _handleKey,
      // Expand to fill the player so the Focus is always "on top" and catches
      // all D-pad events (just like the phone's GestureDetector).
      child: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Bottom control bar ─────────────────────────────────────────
            AnimatedOpacity(
              opacity: widget.barVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 220),
              child: IgnorePointer(
                ignoring: !widget.barVisible,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FocusScope(
                    node: _barScope,
                    child: SafeArea(
                      top: false,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Color(0xE6000000), Color(0x00000000)],
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              for (final (icon, label, cb) in buttons)
                                TvFocusable(
                                  onTap: () {
                                    cb();
                                    _scheduleHide(); // reset idle timer on any action
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          icon,
                                          color: Colors.white,
                                          size: 26,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          label,
                                          style: AppText.caption.copyWith(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
