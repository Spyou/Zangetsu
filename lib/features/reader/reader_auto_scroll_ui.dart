import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'reader_auto_scroll.dart';
import 'reader_chrome.dart';

/// Small floating play/pause for auto-scroll, parked above the bottom chrome.
///
/// Exists because the alternative is revealing the chrome every time you want
/// to pause — which rather defeats a hands-free mode. Only shown while
/// auto-scroll is on, so it costs nothing the rest of the time.
class ReaderAutoScrollButton extends StatefulWidget {
  const ReaderAutoScrollButton({
    super.key,
    required this.autoScroll,
    required this.onTap,
    required this.initialX,
    required this.initialY,
    required this.onMoved,
  });

  final ReaderAutoScroll autoScroll;

  /// Opens the auto-scroll sheet. Tapping used to stop auto-scroll outright,
  /// which made the button a one-way trip — you could turn it off from the
  /// page but never adjust it without digging through the chrome.
  final VoidCallback onTap;

  /// Position as a fraction of the screen, 0–1 on each axis.
  final double initialX;
  final double initialY;
  final void Function(double x, double y) onMoved;

  @override
  State<ReaderAutoScrollButton> createState() => _ReaderAutoScrollButtonState();
}

class _ReaderAutoScrollButtonState extends State<ReaderAutoScrollButton> {
  static const double _size = 46;

  late double _x = widget.initialX;
  late double _y = widget.initialY;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    // Kept in fractions but positioned in pixels, clamped so the button can
    // never be dragged under the status bar or off an edge and stranded.
    final maxLeft = (screen.width - _size).clamp(0.0, double.infinity);
    final maxTop = (screen.height - _size).clamp(0.0, double.infinity);
    final left = (_x * screen.width).clamp(0.0, maxLeft);
    final top = (_y * screen.height).clamp(
      MediaQuery.paddingOf(context).top + 8,
      maxTop,
    );

    // ALWAYS a Positioned, even when hidden. A Stack sizes itself to its
    // largest NON-positioned child, and every other child of the reader's
    // stack is positioned — so returning a bare SizedBox.shrink() here
    // collapsed the whole stack to 0x0 and the page vanished. Costly lesson;
    // the empty case has to stay positioned too.
    return Positioned(
      left: left,
      top: top,
      child: ValueListenableBuilder<bool>(
        valueListenable: widget.autoScroll.running,
        builder: (context, running, _) {
          if (!running) return const SizedBox.shrink();
          return ValueListenableBuilder<bool>(
            valueListenable: widget.autoScroll.paused,
            builder: (context, paused, _) => Semantics(
              button: true,
              label: 'Auto-scroll settings',
              child: GestureDetector(
                // Both on one detector so a press either taps or drags — the
                // gesture arena sorts out which, and a drag never fires the tap.
                onTap: widget.onTap,
                onPanStart: (_) => setState(() => _dragging = true),
                onPanUpdate: (d) {
                  setState(() {
                    _x = ((left + d.delta.dx) / screen.width).clamp(0.0, 1.0);
                    _y = ((top + d.delta.dy) / screen.height).clamp(0.0, 1.0);
                  });
                },
                onPanEnd: (_) {
                  setState(() => _dragging = false);
                  widget.onMoved(_x, _y);
                },
                child: Opacity(
                  // Semi-transparent at rest, unlike the top/bottom pills.
                  // Those appear only when you ask for them; this one sits over
                  // the page for the whole run, so at full strength it's a
                  // permanent hole in the art. Solid enough to find, faint
                  // enough to read through — and firmer while you're dragging
                  // it, where you actually want to see what you're moving.
                  opacity: _dragging ? 0.9 : 0.55,
                  child: SizedBox(
                    width: _size,
                    height: _size,
                    child: ReaderPillSurface(
                      radius: _size / 2,
                      child: Center(
                        child: Icon(
                          // Shows what's happening, not what tapping does:
                          // while your finger is down it's genuinely paused,
                          // and an icon that flickers as you touch the page
                          // would be worse than one that just reports.
                          paused ? Icons.pause_rounded : Icons.motion_photos_on,
                          size: 22,
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The auto-scroll controls, as their own sheet rather than a row crammed into
/// the bottom pill: enable, speed, and whether to keep the floating button.
class ReaderAutoScrollSheet extends StatefulWidget {
  const ReaderAutoScrollSheet({
    super.key,
    required this.running,
    required this.speed,
    required this.showButton,
    required this.onToggle,
    required this.onSpeed,
    required this.onShowButton,
  });

  final bool running;
  final double speed;
  final bool showButton;
  final ValueChanged<bool> onToggle;
  final ValueChanged<double> onSpeed;
  final ValueChanged<bool> onShowButton;

  @override
  State<ReaderAutoScrollSheet> createState() => _ReaderAutoScrollSheetState();
}

class _ReaderAutoScrollSheetState extends State<ReaderAutoScrollSheet> {
  late bool _running = widget.running;
  late double _speed = widget.speed;
  late bool _showButton = widget.showButton;

  @override
  Widget build(BuildContext context) {
    return readerSheetBody(
      context: context,
      title: 'Auto-scroll',
      subtitle: 'Touch the page to pause — it picks up again when you let go.',
      children: [
        readerSheetSection('Scrolling'),
        readerSheetGroup([
          readerSheetRow(
            icon: Icons.play_circle_outline_rounded,
            label: 'Auto-scroll',
            trailing: Switch(
              value: _running,
              activeThumbColor: AppColors.accent,
              onChanged: (v) {
                setState(() => _running = v);
                widget.onToggle(v);
                // Starting it and leaving the sheet over the page would hide
                // the thing you just asked to watch.
                if (v) Navigator.of(context).maybePop();
              },
            ),
          ),
          readerSheetRow(
            icon: Icons.speed_rounded,
            label: 'Speed',
            trailing: Text(
              _speed.round().toString(),
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
            child: Slider(
              value: _speed.clamp(1, 10),
              min: 1,
              max: 10,
              divisions: 9,
              activeColor: AppColors.accent,
              onChanged: (v) {
                setState(() => _speed = v);
                widget.onSpeed(v);
              },
            ),
          ),
        ]),
        readerSheetSection('Control'),
        readerSheetGroup([
          readerSheetRow(
            icon: Icons.smart_button_rounded,
            label: 'Floating button',
            trailing: Switch(
              value: _showButton,
              activeThumbColor: AppColors.accent,
              onChanged: (v) {
                setState(() => _showButton = v);
                widget.onShowButton(v);
              },
            ),
          ),
        ]),
      ],
    );
  }
}
