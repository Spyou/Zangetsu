// Brightness/volume HUD, the double-tap seek indicator and the info card.
part of 'player_screen.dart';

class _AdjustHud extends StatelessWidget {
  const _AdjustHud({required this.value, required this.isBrightness});

  final double value; // 0..1
  final bool isBrightness;

  IconData get _icon {
    if (isBrightness) {
      return value < 0.35
          ? Icons.brightness_low_rounded
          : (value < 0.7
                ? Icons.brightness_medium_rounded
                : Icons.brightness_high_rounded);
    }
    return value <= 0.01
        ? Icons.volume_off_rounded
        : (value < 0.5 ? Icons.volume_down_rounded : Icons.volume_up_rounded);
  }

  @override
  Widget build(BuildContext context) {
    // Volume runs 0–200% (in-app boost); brightness stays 0–100%.
    final pct = ((isBrightness ? 1 : 2) * value * 100).round();
    // Tint the boost zone (>100%) red as a warning, like CloudStream.
    final boosted = !isBrightness && pct > 100;
    final fillColor = boosted ? Colors.red : AppColors.accent;
    // The track fill maps the full range onto 0..1 — volume is half-full at 100%.
    final fill = value.clamp(0.0, 1.0);
    final tint = boosted ? Colors.red : Colors.white;
    // Same translucent-black capsule as the transport discs and the bottom
    // chips — this was the last piece of the player still on its own look
    // (a near-opaque 0.78 slab with a glowing fill).
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Percentage on top. Tabular digits matter more here than anywhere
            // else in the player: this number changes continuously under your
            // thumb, and proportional figures make it jitter the whole way.
            Text(
              '$pct%',
              style: AppText.caption.copyWith(
                color: tint,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
                height: 1.1,
                letterSpacing: 0.3,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 10),
            // Vertical fill track (bottom-anchored). Accent, matching the seek
            // bar's played portion — but no glow: nothing else in the player
            // glows any more, and it was the loudest thing on screen.
            SizedBox(
              width: 6,
              height: 118,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedFractionallySizedBox(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      heightFactor: fill,
                      widthFactor: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: fillColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // Icon at the bottom.
            Icon(_icon, color: tint, size: 20),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Double-tap seek indicator — a soft side-anchored ripple with animated
// chevrons and the running ±Ns amount, YouTube-style. Re-pulses whenever the
// accumulated value changes (each rapid tap), and fades as the burst ends.
// ─────────────────────────────────────────────────────────────────────────────

class _SeekIndicator extends StatefulWidget {
  const _SeekIndicator({
    super.key,
    required this.side,
    required this.accumSeconds,
  });

  final int side; // -1 = rewind (left), +1 = forward (right)
  final int accumSeconds; // running total this burst (shown in the pill)

  @override
  State<_SeekIndicator> createState() => _SeekIndicatorState();
}

class _SeekIndicatorState extends State<_SeekIndicator>
    with SingleTickerProviderStateMixin {
  // Re-keyed per tap by the parent, so a fresh state replays the slide/fade-in.
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  )..forward();

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.side < 0;
    final curve = CurvedAnimation(parent: _in, curve: Curves.easeOutCubic);
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: left ? const Alignment(-0.55, 0) : const Alignment(0.55, 0),
          child: FadeTransition(
            opacity: curve,
            child: SlideTransition(
              // Settle in from the tapped edge.
              position: Tween<Offset>(
                begin: Offset(left ? -0.06 : 0.06, 0),
                end: Offset.zero,
              ).animate(curve),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Accent icon disc — surface2 chip + a soft coral glow, the
                  // app's in-player signature (matches the 2× / volume chips).
                  Container(
                    width: 66,
                    height: 66,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      // Semi-transparent so the video breathes through.
                      color: AppColors.surface2.withValues(alpha: 0.78),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.accentSoft,
                          blurRadius: 16,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Icon(
                      left
                          ? Icons.fast_rewind_rounded
                          : Icons.fast_forward_rounded,
                      color: AppColors.accent,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Running-total pill (−/+ Ns) — same chip as the 2× hold pill.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.surface2.withValues(alpha: 0.78),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      child: Text(
                        '${left ? '−' : '+'}${widget.accumSeconds}s',
                        style: AppText.caption.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Controls overlay — top bar, center transport, bottom seek + button row.
// ─────────────────────────────────────────────────────────────────────────────

class _InfoOverlay extends StatefulWidget {
  const _InfoOverlay({required this.controller, required this.fields});
  final PlayerCubit controller;
  final List<String> fields;

  @override
  State<_InfoOverlay> createState() => _InfoOverlayState();
}

class _InfoOverlayState extends State<_InfoOverlay> {
  Map<String, String> _values = const {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final c = widget.controller;
    final st = c.player.state;
    final out = <String, String>{};
    for (final key in widget.fields) {
      switch (key) {
        case 'resolution':
          final w = st.width ?? 0, h = st.height ?? 0;
          out[key] = (w > 0 && h > 0) ? '$w×$h' : '—';
        case 'source':
          final l = c.state.active?.label?.trim();
          out[key] = (l != null && l.isNotEmpty) ? l : '—';
        case 'quality':
          out[key] = c.state.active?.quality ?? 'auto';
        case 'buffer':
          out[key] = '${st.buffer.inSeconds}s';
        case 'decoder':
          out[key] = _decoderLabel(sl<PlaybackPrefs>().videoDecoder);
        case 'speed':
          out[key] = '${st.rate}×';
        case 'atrack':
          out[key] = _trackLabel(st.track.audio.id, st.track.audio.title,
              st.track.audio.language);
        case 'strack':
          out[key] = _trackLabel(st.track.subtitle.id, st.track.subtitle.title,
              st.track.subtitle.language);
        case 'vcodec':
          out[key] = await c.mpvStat('video-codec') ?? '—';
        case 'acodec':
          out[key] = await c.mpvStat('audio-codec') ?? '—';
        case 'fps':
          final f = await c.mpvStat('estimated-vf-fps');
          out[key] =
              f == null ? '—' : (double.tryParse(f)?.toStringAsFixed(2) ?? f);
        case 'vbitrate':
          out[key] = _bitrate(await c.mpvStat('video-bitrate'));
        case 'dropped':
          out[key] = await c.mpvStat('frame-drop-count') ?? '0';
        case 'af':
          // Live mpv softvol level (the real applied gain), e.g. "200%".
          final v = await c.mpvStat('volume');
          final n = double.tryParse(v ?? '');
          out[key] = n == null ? '—' : '${n.round()}%';
      }
    }
    if (mounted) setState(() => _values = out);
  }

  String _decoderLabel(String mode) => switch (mode) {
    'direct' => 'Hardware',
    'sw' => 'Software',
    'auto' => 'Auto',
    _ => 'Hardware+', // copy
  };

  String _trackLabel(String id, String? title, String? language) {
    if (id == 'no') return 'Off';
    final t = title?.trim();
    if (t != null && t.isNotEmpty) return t;
    final l = language?.trim();
    if (l != null && l.isNotEmpty) return l;
    return id;
  }

  String _bitrate(String? bps) {
    final v = int.tryParse(bps ?? '');
    if (v == null || v <= 0) return '—';
    return v >= 1000000
        ? '${(v / 1000000).toStringAsFixed(1)} Mbps'
        : '${(v / 1000).round()} kbps';
  }

  @override
  Widget build(BuildContext context) {
    final labels = {for (final f in kPlayerInfoFields) f.$1: f.$2};
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final key in widget.fields)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text.rich(
                    TextSpan(
                      style: const TextStyle(fontSize: 11, height: 1.35),
                      children: [
                        TextSpan(
                          text: '${labels[key] ?? key}  ',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        TextSpan(
                          text: _values[key] ?? '…',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
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
    );
  }
}

/// Small grouped-section label inside a sheet (e.g. "Version" / "Audio track").
