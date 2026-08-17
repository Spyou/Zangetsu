import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// The small control set for the portrait player. Deliberately short: speed,
/// quality, audio, subtitles, sources and fit all stay in fullscreen.
class WatchMiniControls extends StatefulWidget {
  const WatchMiniControls({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onSeek,
    required this.onFullscreen,
    this.onScrub,
  });

  final bool playing;
  final Duration position;
  final Duration duration;
  final VoidCallback onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onFullscreen;

  /// Fired on every drag tick (no seek attached) — lets the host keep its
  /// auto-hiding controls up while a scrub is in progress. Optional so the
  /// existing widget test (which doesn't care about the auto-hide timer)
  /// keeps compiling unchanged.
  final VoidCallback? onScrub;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  State<WatchMiniControls> createState() => _WatchMiniControlsState();
}

class _WatchMiniControlsState extends State<WatchMiniControls> {
  // Held while the thumb is being dragged so the live position stream (which
  // keeps calling setState on the host every tick) can't yank it back mid-drag.
  // Committed as the real seek only once the drag ends.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds;
    final at = widget.position.inMilliseconds.clamp(0, total == 0 ? 1 : total);
    final sliderValue = _dragValue ?? at.toDouble();
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              padding: EdgeInsets.zero,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: AppColors.accent,
            ),
            child: Slider(
              value: sliderValue,
              max: (total == 0 ? 1 : total).toDouble(),
              onChanged: (v) {
                setState(() => _dragValue = v);
                widget.onScrub?.call();
              },
              onChangeEnd: (v) {
                setState(() => _dragValue = null);
                widget.onSeek(Duration(milliseconds: v.round()));
              },
            ),
          ),
          Row(
            children: [
              IconButton(
                key: const Key('watch-prev'),
                onPressed: widget.onPrevious,
                icon: const Icon(Icons.skip_previous_rounded),
                color: Colors.white,
                disabledColor: Colors.white30,
                iconSize: 22,
              ),
              IconButton(
                onPressed: widget.onPlayPause,
                icon: Icon(
                  widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                color: Colors.white,
                iconSize: 26,
              ),
              IconButton(
                key: const Key('watch-next'),
                onPressed: widget.onNext,
                icon: const Icon(Icons.skip_next_rounded),
                color: Colors.white,
                disabledColor: Colors.white30,
                iconSize: 22,
              ),
              const Spacer(),
              Text(
                '${WatchMiniControls._fmt(widget.position)} / '
                '${WatchMiniControls._fmt(widget.duration)}',
                style: AppText.caption.copyWith(color: Colors.white70),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const Key('watch-fullscreen'),
                onPressed: widget.onFullscreen,
                icon: const Icon(Icons.fullscreen_rounded),
                color: Colors.white,
                iconSize: 24,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
