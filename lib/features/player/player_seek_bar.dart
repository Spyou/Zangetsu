// Scrubber row, its buffered-range track and the thumbnail preview bubble.
part of 'player_screen.dart';

class _SeekRow extends StatefulWidget {
  const _SeekRow({
    required this.controller,
    required this.duration,
    required this.onInteract,
    this.trailing,
  });

  final PlayerCubit controller;
  final Duration duration;
  final VoidCallback onInteract;

  /// Sits at the far end of the timestamp's line (the MegaSkip pill). Riding
  /// the same row costs no extra height — it used to own a line to itself,
  /// which pushed it well clear of the bar it belongs to.
  final Widget? trailing;

  @override
  State<_SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends State<_SeekRow> {
  // While the user is dragging the thumb, hold the value locally so the live
  // position stream doesn't yank it back (which made it feel un-draggable).
  double? _dragMs;

  // The live thumb only creeps forward, but the raw position stream fires ~once
  // per decoded frame — so the whole Slider (with its custom buffered track)
  // rebuilt every frame while the controls were up, dragging the panel down to
  // a GPU-bound ~20fps. Sample to ~4Hz: invisible for a slowly-advancing thumb,
  // and scrubbing stays perfectly smooth because it runs off _dragMs, not this.
  late final Stream<Duration> _livePosition = widget
      .controller.player.stream.position
      .map((p) => Duration(milliseconds: (p.inMilliseconds ~/ 250) * 250))
      .distinct();

  // Tap the right-hand time to flip between total duration and remaining time
  // (a negative countdown, e.g. "−1:00"), CloudStream-style.
  bool _showRemaining = false;

  // Netflix-style scrub preview: a hidden second player/decoder renders the
  // frame at the drag position. Kept alive for the whole session so only the
  // first scrub pays the open cost; online (mpv) re-opening every drag is what
  // made the box take ages to appear.
  SeekPreview? _preview;
  bool _prewarmed = false;

  // Open the online (mpv) preview engine ahead of the first drag so the stream
  // is already loaded by the time the user scrubs — avoids the long "hold and
  // wait" for the box to appear. Offline (MMR) is instant, so no pre-warm.
  void _maybePrewarm() {
    // Online scrub preview removed (see _previewEnabled) — this stays inert:
    // the local check returns for downloads, and online no longer enables.
    if (_prewarmed) return;
    final c = widget.controller;
    if (c.previewUri == null || c.isLocalMedia) return;
    if (!sl<PlaybackPrefs>().seekPreviewOnline) return;
    _prewarmed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ensurePreview();
      _preview?.request(c.player.state.position);
    });
  }

  bool get _previewEnabled {
    final c = widget.controller;
    if (c.previewUri == null) return false;
    // Online scrub preview removed — the hidden second-mpv engine was flaky
    // (screenshots often came back empty) and re-downloaded the stream just to
    // make thumbnails. Only local (download) previews remain: instant and free.
    return c.isLocalMedia;
    // return c.isLocalMedia || sl<PlaybackPrefs>().seekPreviewOnline;
  }

  void _ensurePreview() {
    final c = widget.controller;
    if (!_previewEnabled) {
      _preview?.dispose();
      _preview = null;
      return;
    }
    // Recreate if the active source changed (quality/source switch) so we don't
    // preview a stale URL.
    if (_preview != null && _preview!.uri != c.previewUri) {
      _preview!.dispose();
      _preview = null;
    }
    _preview ??= SeekPreview(
      uri: c.previewUri!,
      headers: c.previewHeaders,
      local: c.isLocalMedia,
    );
  }

  void _requestPreview(double ms) =>
      _preview?.request(Duration(milliseconds: ms.round()));

  @override
  void dispose() {
    _preview?.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    _maybePrewarm();
    final totalMs = widget.duration.inMilliseconds;
    final max = totalMs > 0 ? totalMs.toDouble() : 1.0;
    return StreamBuilder<Duration>(
      stream: _livePosition,
      builder: (context, snap) {
        final streamMs = (snap.data ?? Duration.zero).inMilliseconds
            .clamp(0, max.toInt())
            .toDouble();
        // Use the drag value while scrubbing, else the live position.
        final value = (_dragMs ?? streamMs).clamp(0.0, max);
        final shownPos = Duration(milliseconds: value.round());
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Elapsed / total sits above the bar so the bar itself can run the
            // full width — easier to scrub, and it reads as one clean line.
            // Tapping still flips the total for a remaining countdown. Anything
            // passed as [trailing] shares this line at the far end.
            Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() => _showRemaining = !_showRemaining);
                    widget.onInteract();
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                // Same translucent chip as the button groups, so the whole
                // bottom block reads as one set of parts.
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Text(
                      '${_fmt(shownPos)} / ${_showRemaining ? '-${_fmt(widget.duration - shownPos)}' : _fmt(widget.duration)}',
                      style: AppText.caption.copyWith(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                        letterSpacing: 0.3,
                        // Fixed-width digits: without these the label twitches
                        // every time a 1 ticks past, since 1 is narrower than
                        // the rest in a proportional face.
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                  ),
                ),
                if (widget.trailing != null) ...[
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: widget.trailing!,
                  ),
                ],
              ],
            ),
            SizedBox(
              width: double.infinity,
              child: LayoutBuilder(
                builder: (context, cons) {
                  final w = cons.maxWidth;
                  final frac = max > 0 ? (value / max).clamp(0.0, 1.0) : 0.0;
                  const bubbleW = 168.0;
                  final left = (frac * w - bubbleW / 2).clamp(
                    0.0,
                    (w - bubbleW).clamp(0.0, double.infinity),
                  );
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      SizedBox(
                        width: w,
                        child: StreamBuilder<Duration>(
                          stream: widget.controller.player.stream.buffer,
                          builder: (context, bufSnap) {
                            final bufMs =
                                (bufSnap.data ?? Duration.zero).inMilliseconds;
                            final bufferedFrac = totalMs > 0
                                ? (bufMs / totalMs).clamp(0.0, 1.0)
                                : 0.0;
                            return SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: AppColors.accent,
                                inactiveTrackColor: Colors.white24,
                                trackShape: _BufferedSliderTrackShape(
                                  buffered: bufferedFrac,
                                  bufferedColor: Colors.white.withValues(
                                    alpha: 0.55,
                                  ),
                                  marks: [
                                    if (totalMs > 0 &&
                                        sl<PlaybackPrefs>().skipIntro)
                                      for (final iv
                                          in widget.controller.currentSkips) ...[
                                        (iv.start.inMilliseconds / totalMs)
                                            .clamp(0.0, 1.0),
                                        (iv.end.inMilliseconds / totalMs)
                                            .clamp(0.0, 1.0),
                                      ],
                                  ],
                                ),
                                thumbColor: Colors.white,
                                overlayColor: AppColors.accentSoft,
                                trackHeight: 6,
                                // Thumb grows while scrubbing (YouTube-style).
                                thumbShape: RoundSliderThumbShape(
                                  enabledThumbRadius: _dragMs != null ? 11 : 7,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 18,
                                ),
                              ),
                              child: Slider(
                                min: 0,
                                max: max,
                                value: value,
                                // Replaces the default inset — half the overlay
                                // width (~18px) horizontally, the overlay height
                                // vertically, which was most of the dead space
                                // around the bar. Horizontal is the thumb radius
                                // exactly: the thumb centres on the track's end,
                                // so anything less and half the dot hangs past
                                // the line the chips above and below sit on.
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 6,
                                ),
                                onChangeStart: totalMs <= 0
                                    ? null
                                    : (v) {
                                        _ensurePreview();
                                        setState(() => _dragMs = v);
                                        _requestPreview(v);
                                        widget.onInteract();
                                      },
                                onChanged: totalMs <= 0
                                    ? null
                                    : (v) {
                                        setState(() => _dragMs = v);
                                        _requestPreview(v);
                                        widget.onInteract();
                                      },
                                onChangeEnd: totalMs <= 0
                                    ? null
                                    : (v) {
                                        widget.controller.seekTo(
                                          Duration(milliseconds: v.round()),
                                        );
                                        setState(() => _dragMs = null);
                                        widget.onInteract();
                                      },
                              ),
                            );
                          },
                        ),
                      ),
                      // Off-screen 1px Video that drives mpv frame rendering
                      // for online previews — mpv only produces screenshot-able
                      // frames when its texture is actually painted. Kept
                      // mounted whenever the preview player exists (not only
                      // mid-drag) so it stays warm between scrubs.
                      if (_preview != null && _preview!.usesVideo)
                        Positioned(
                          left: 0,
                          top: 0,
                          width: 1,
                          height: 1,
                          child: IgnorePointer(
                            child: ValueListenableBuilder<VideoController?>(
                              valueListenable: _preview!.videoController,
                              builder: (context, vc, _) => vc == null
                                  ? const SizedBox.shrink()
                                  : Video(
                                      controller: vc,
                                      controls: NoVideoControls,
                                      fill: Colors.transparent,
                                    ),
                            ),
                          ),
                        ),
                      if (_dragMs != null)
                        Positioned(
                          left: left,
                          bottom: 26,
                          width: bubbleW,
                          child: _PreviewBubble(
                            preview: _preview,
                            time: _fmt(shownPos),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Seek-bar track that draws three layers like YouTube/Netflix: faint
/// background (unbuffered), a lighter "buffered" layer up to [buffered]
/// (fetched-ahead), and the accent played layer up to the thumb.
class _BufferedSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  _BufferedSliderTrackShape({
    required this.buffered,
    required this.bufferedColor,
    this.marks = const [],
  });

  /// Buffered fraction in [0, 1].
  final double buffered;
  final Color bufferedColor;

  /// Chapter/skip marker fractions in [0, 1] (AniSkip OP/ED boundaries),
  /// drawn as small notches poking above/below the track.
  final List<double> marks;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final radius = Radius.circular(rect.height / 2);
    final canvas = context.canvas;

    // 1. Background (unbuffered remainder).
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, radius),
      Paint()..color = sliderTheme.inactiveTrackColor ?? Colors.white24,
    );

    // 2. Buffered (fetched ahead).
    if (buffered > 0) {
      final bw = rect.width * buffered.clamp(0.0, 1.0);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(rect.left, rect.top, bw, rect.height),
          radius,
        ),
        Paint()..color = bufferedColor,
      );
    }

    // 3. Played (up to the thumb).
    final activeRight = thumbCenter.dx.clamp(rect.left, rect.right);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(rect.left, rect.top, activeRight, rect.bottom),
        radius,
      ),
      Paint()..color = sliderTheme.activeTrackColor ?? AppColors.accent,
    );

    // 4. Chapter / skip markers (AniSkip OP/ED boundaries) — small notches
    // that overhang the track so they read as markers, not part of the fill.
    if (marks.isNotEmpty) {
      final markPaint = Paint()..color = Colors.white.withValues(alpha: 0.95);
      final h = rect.height + 4;
      for (final m in marks) {
        final x = rect.left + rect.width * m.clamp(0.0, 1.0);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x, rect.center.dy), width: 3, height: h),
            const Radius.circular(1.5),
          ),
          markPaint,
        );
      }
    }
  }
}

/// Floating thumbnail shown above the seek-bar thumb while scrubbing. Shows the
/// preview frame once one is available (never a loading spinner) with the
/// target time beneath it. Until a frame lands — or on sources that can't be
/// previewed — it's just a plain time bubble.
class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({required this.preview, required this.time});

  final SeekPreview? preview;
  final String time;

  @override
  Widget build(BuildContext context) {
    final p = preview;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (p != null)
          ValueListenableBuilder<Uint8List?>(
            valueListenable: p.frame,
            builder: (context, bytes, _) {
              if (bytes == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 168,
                    height: 94,
                    color: Colors.black,
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              );
            },
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              time,
              style: AppText.caption.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small bits.
// ─────────────────────────────────────────────────────────────────────────────

// Netflix-style "Skip intro/ending" pill — fades + slides up when it appears
// (it's mounted only while inside an AniSkip interval), with a ripple + a
// premium rounded look. A press-scale gives tactile feedback.
