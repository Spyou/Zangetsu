// Chromecast transport, shown while casting.
part of 'player_screen.dart';

class _CastRemotePanel extends StatefulWidget {
  const _CastRemotePanel({
    required this.deviceName,
    required this.showTitle,
    required this.cover,
    required this.onBack,
    required this.onStop,
    this.loadError,
  });

  final String deviceName;
  final String? showTitle;
  final String? cover;
  final String? loadError;
  final VoidCallback onBack;
  final VoidCallback onStop;

  @override
  State<_CastRemotePanel> createState() => _CastRemotePanelState();
}

class _CastRemotePanelState extends State<_CastRemotePanel> {
  // While the user drags the seek thumb, hold the value locally so the live
  // cast position stream doesn't yank it back.
  double? _dragMs;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.92),
      child: SafeArea(
        child: Column(
          children: [
            // Top bar — back + "Casting to <TV>" heading.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    tooltip: context.l10n.back,
                    onPressed: widget.onBack,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.cast_connected,
                              color: AppColors.accent,
                              size: 18,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Casting to ${widget.deviceName}',
                              style: AppText.caption.copyWith(
                                color: AppColors.accent,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        if (widget.showTitle != null)
                          Text(
                            widget.showTitle!,
                            style: AppText.headline.copyWith(color: Colors.white),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Poster art (optional) + centre transport controls (or error).
            Expanded(
              child: widget.loadError != null
                  // ── Load-error state ──────────────────────────────────────
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.cast_connected,
                              color: Colors.white38,
                              size: 56,
                            ),
                            const SizedBox(height: 20),
                            const Text(
                              "This source can't be cast — try another source.",
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  // ── Normal playback state ─────────────────────────────────
                  : AnimatedBuilder(
                      animation: sl<CastController>(),
                      builder: (context, _) {
                        final castCtrl = sl<CastController>();
                        final isPlaying = castCtrl.isPlaying;
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Optional poster thumbnail.
                            if (widget.cover != null && widget.cover!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 24),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: CachedNetworkImage(
                                    imageUrl: widget.cover!,
                                    height: 120,
                                    fit: BoxFit.contain,
                                    errorWidget: (_, _, _) =>
                                        const SizedBox.shrink(),
                                  ),
                                ),
                              ),

                            // Transport: −10s / play-pause / +10s.
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  iconSize: 40,
                                  icon: const Icon(
                                    Icons.replay_10,
                                    color: Colors.white,
                                  ),
                                  tooltip: context.l10n.rewind10Seconds,
                                  onPressed: () {
                                    final target =
                                        castCtrl.position -
                                        const Duration(seconds: 10);
                                    castCtrl.seek(
                                      target < Duration.zero
                                          ? Duration.zero
                                          : target,
                                    );
                                  },
                                ),
                                const SizedBox(width: 24),
                                IconButton(
                                  iconSize: 56,
                                  icon: Icon(
                                    isPlaying
                                        ? Icons.pause_circle_filled
                                        : Icons.play_circle_filled,
                                    color: Colors.white,
                                  ),
                                  tooltip: isPlaying ? 'Pause' : 'Play',
                                  onPressed: () => isPlaying
                                      ? castCtrl.pause()
                                      : castCtrl.play(),
                                ),
                                const SizedBox(width: 24),
                                IconButton(
                                  iconSize: 40,
                                  icon: const Icon(
                                    Icons.forward_10,
                                    color: Colors.white,
                                  ),
                                  tooltip: context.l10n.forward10Seconds,
                                  onPressed: () {
                                    final dur = castCtrl.duration;
                                    final target =
                                        castCtrl.position +
                                        const Duration(seconds: 10);
                                    castCtrl.seek(
                                      dur > Duration.zero && target > dur
                                          ? dur
                                          : target,
                                    );
                                  },
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
            ),

            // Seek bar + stop button at the bottom.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: AnimatedBuilder(
                animation: sl<CastController>(),
                builder: (context, _) {
                  final castCtrl = sl<CastController>();
                  final pos = castCtrl.position;
                  final dur = castCtrl.duration;
                  final totalMs =
                      dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
                  final posMs = pos.inMilliseconds
                      .clamp(0, totalMs.toInt())
                      .toDouble();
                  final value = (_dragMs ?? posMs).clamp(0.0, totalMs);

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Time + seek bar + total — hidden when load failed.
                      if (widget.loadError == null) ...[
                        Row(
                          children: [
                            Text(
                              _fmt(Duration(milliseconds: value.round())),
                              style: AppText.caption.copyWith(color: Colors.white),
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  activeTrackColor: AppColors.accent,
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: Colors.white,
                                  overlayColor: AppColors.accentSoft,
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 7,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 16,
                                  ),
                                ),
                                child: Slider(
                                  min: 0,
                                  max: totalMs,
                                  value: value,
                                  onChangeStart: dur <= Duration.zero
                                      ? null
                                      : (v) => setState(() => _dragMs = v),
                                  onChanged: dur <= Duration.zero
                                      ? null
                                      : (v) => setState(() => _dragMs = v),
                                  onChangeEnd: dur <= Duration.zero
                                      ? null
                                      : (v) {
                                          castCtrl.seek(
                                            Duration(milliseconds: v.round()),
                                          );
                                          setState(() => _dragMs = null);
                                        },
                                ),
                              ),
                            ),
                            Text(
                              _fmt(dur),
                              style: AppText.caption.copyWith(color: Colors.white),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],

                      // Stop casting button — always visible.
                      TextButton.icon(
                        onPressed: widget.onStop,
                        icon: const Icon(
                          Icons.cast,
                          color: Colors.white70,
                          size: 18,
                        ),
                        label: const Text(
                          'Stop casting',
                          style: TextStyle(color: Colors.white70),
                        ),
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.white12,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Brightness / volume HUD — a compact dark side-rail bar with a percentage on
// top, a vertical fill track and an icon at the bottom, pinned to the half being
// swiped while the user drags (MX Player / CloudStream-style).
// ─────────────────────────────────────────────────────────────────────────────

