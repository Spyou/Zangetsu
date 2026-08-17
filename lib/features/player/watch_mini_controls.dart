import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// The small control set for the portrait player. Deliberately short: speed,
/// quality, audio, subtitles, sources and fit all stay in fullscreen.
class WatchMiniControls extends StatelessWidget {
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
  });

  final bool playing;
  final Duration position;
  final Duration duration;
  final VoidCallback onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onFullscreen;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds;
    final at = position.inMilliseconds.clamp(0, total == 0 ? 1 : total);
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
              value: at.toDouble(),
              max: (total == 0 ? 1 : total).toDouble(),
              onChanged: (v) => onSeek(Duration(milliseconds: v.round())),
            ),
          ),
          Row(
            children: [
              IconButton(
                key: const Key('watch-prev'),
                onPressed: onPrevious,
                icon: const Icon(Icons.skip_previous_rounded),
                color: Colors.white,
                disabledColor: Colors.white30,
                iconSize: 22,
              ),
              IconButton(
                onPressed: onPlayPause,
                icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                color: Colors.white,
                iconSize: 26,
              ),
              IconButton(
                key: const Key('watch-next'),
                onPressed: onNext,
                icon: const Icon(Icons.skip_next_rounded),
                color: Colors.white,
                disabledColor: Colors.white30,
                iconSize: 22,
              ),
              const Spacer(),
              Text('${_fmt(position)} / ${_fmt(duration)}',
                  style: AppText.caption.copyWith(color: Colors.white70)),
              const SizedBox(width: 4),
              IconButton(
                key: const Key('watch-fullscreen'),
                onPressed: onFullscreen,
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
