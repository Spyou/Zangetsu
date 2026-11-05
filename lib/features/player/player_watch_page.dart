import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/frosted_surface.dart';
import '../../l10n/l10n.dart';
import 'watch_page_info.dart';

/// Portrait watch page: the stable video surface on top, episode info below.
///
/// Owns NO playback decisions. Everything arrives as immutable data plus
/// callbacks; position ticks rebuild only the seek row, never the info below.
class PlayerWatchPage extends StatefulWidget {
  const PlayerWatchPage({
    super.key,
    required this.video,
    required this.header,
    this.coverHeaders,
    this.loading = false,
    this.firstFrameStream,
    this.initialFirstFrame = 0,
    this.ambientFrameStream,
    required this.positionStream,
    required this.durationStream,
    required this.playingStream,
    required this.initialPlaying,
    required this.initialPosition,
    required this.initialDuration,
    required this.hasPrevious,
    this.nextThumb,
    this.nextLabel,
    this.nextTitle,
    required this.autoplay,
    required this.episodes,
    this.serverName,
    this.coverUrl,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onPrevious,
    required this.onNext,
    required this.onFullscreen,
    required this.onBack,
    required this.onServer,
    required this.onAudio,
    required this.onSubtitles,
    required this.onMore,
    required this.onOpenEpisode,
    required this.onComments,
    required this.onAutoplayChanged,
  });

  /// The one video surface, built by the parent. This page only sizes it.
  final Widget video;
  final WatchPageHeader header;
  final Map<String, String>? coverHeaders;

  /// A resolve is in flight (episode switch or first load). The page stays —
  /// the spinner sits on the mini player instead of a black loader screen.
  final bool loading;

  /// First-frame signal (player width; null = latch off). While no frame has
  /// decoded the spinner holds — even if the loading flag lapses between
  /// progressive resolves, and no tap can dismiss it.
  final Stream<int?>? firstFrameStream;
  final int initialFirstFrame;

  /// Live video frame for the ambient glow (see [_ambientBackdrop]). Null
  /// stream = still art only.
  final Stream<Uint8List?>? ambientFrameStream;
  final Stream<Duration> positionStream;
  final Stream<Duration?> durationStream;
  final Stream<bool> playingStream;
  final bool initialPlaying;

  /// Last known values at handoff. The streams below don't replay, so without
  /// these a layout switch reads 00:00 until the next tick — or forever when
  /// paused.
  final Duration initialPosition;
  final Duration initialDuration;

  final bool hasPrevious;
  final String? nextThumb;
  final String? nextLabel;
  final String? nextTitle;
  final bool autoplay;
  final List<WatchPageEpisode> episodes;
  final String? serverName;
  final String? coverUrl;

  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onFullscreen;
  final VoidCallback onBack;
  final VoidCallback onServer;
  final VoidCallback onAudio;
  final VoidCallback onSubtitles;
  final VoidCallback onMore;
  final ValueChanged<int> onOpenEpisode;
  final VoidCallback onComments;
  final ValueChanged<bool> onAutoplayChanged;

  @override
  State<PlayerWatchPage> createState() => _PlayerWatchPageState();
}

class _PlayerWatchPageState extends State<PlayerWatchPage> {
  bool _controlsVisible = true;
  bool _expanded = false;
  late bool _playing = widget.initialPlaying;
  StreamSubscription<bool>? _playingSub;
  Timer? _hideTimer;

  late final ScrollController _scroll;
  final ValueNotifier<double> _ambientOpacity = ValueNotifier(1);

  /// The row the player is on. The list opens on it and follows it.
  final GlobalKey _currentKey = GlobalKey();
  int _scrolledIndex = -1;

  late bool _frameUp;
  StreamSubscription<int?>? _frameSub;
  StreamSubscription<Uint8List?>? _ambientSub;

  /// The wash colors sampled from the latest frame (or cover).
  Color _glowTop = Colors.black;
  Color _glowBottom = Colors.black;

  /// Bumps per accepted frame so the crossfade always has a new key.
  int _glowRev = 0;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController()..addListener(_fadeAmbient);
    _frameUp = widget.firstFrameStream == null || widget.initialFirstFrame > 0;
    _frameSub = widget.firstFrameStream?.listen((w) {
      if (!mounted || _frameUp || (w ?? 0) <= 0) return;
      setState(() => _frameUp = true);
    });
    _ambientSub = widget.ambientFrameStream?.listen((bytes) {
      if (!mounted || bytes == null || bytes.isEmpty) return;
      unawaited(_applyAmbientBytes(bytes));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrent();
      _sampledCover = null;
      unawaited(_sampleCoverArt());
    });
    _playingSub = widget.playingStream.listen((p) {
      if (!mounted || p == _playing) return;
      setState(() => _playing = p);
      if (p) {
        _armHide();
      } else {
        _hideTimer?.cancel();
        setState(() => _controlsVisible = true);
      }
    });
    _armHide();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _playingSub?.cancel();
    _frameSub?.cancel();
    _ambientSub?.cancel();
    _scroll.dispose();
    _ambientOpacity.dispose();
    super.dispose();
  }

  String? _sampledCover;

  /// Decodes one grab tiny and keeps its mood color. Decoding small keeps
  /// this cheap; a corrupt read never swaps the glow out.
  Future<void> _applyAmbientBytes(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = img.width;
      final h = img.height;
      img.dispose();
      if (data == null || !mounted) return;
      final c = ambientGlowColor(data, w, h);
      if (!mounted) return;
      // A near-black grab on top of an existing glow adds nothing — a
      // paused black frame must not paint the wash away.
      final lum = _luminance(c.top) + _luminance(c.bottom);
      if (lum < 28 && _glowRev > 0) return;
      setState(() {
        _glowTop = c.top;
        _glowBottom = c.bottom;
        _glowRev++;
      });
    } catch (_) {
      // Undecodable grab — keep the previous glow.
    }
  }

  static int _luminance(Color c) =>
      ((c.r * 255).round() + (c.g * 255).round() + (c.b * 255).round()) ~/ 3;

  /// Seeds the wash from the cover art so the page glows before (or without)
  /// any live frame. Runs once per cover; live frames always win afterwards.
  Future<void> _sampleCoverArt() async {
    final cover = (widget.coverUrl ?? '').trim();
    if (cover.isEmpty || !mounted || _sampledCover == cover) return;
    _sampledCover = cover;
    final revAtRequest = _glowRev;
    try {
      final client = HttpClient();
      try {
        final req = await client.getUrl(Uri.parse(cover));
        widget.coverHeaders?.forEach(req.headers.set);
        final resp = await req.close().timeout(const Duration(seconds: 8));
        if (resp.statusCode != HttpStatus.ok) return;
        final bytes = await resp
            .fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d))
            .then((b) => b.takeBytes());
        if (!mounted || widget.coverUrl != cover || _glowRev != revAtRequest) {
          return;
        }
        await _applyAmbientBytes(bytes);
      } finally {
        client.close();
      }
    } catch (_) {
      // Offline cover, bad headers — the page stays on plain black.
    }
  }

  void _fadeAmbient() {
    _ambientOpacity.value = (1 - _scroll.offset / 180).clamp(0.0, 1.0);
  }

  void _scrollToCurrent() {
    final at = widget.episodes.indexWhere((e) => e.current);
    if (at == _scrolledIndex) return;
    _scrolledIndex = at;
    if (at < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _currentKey.currentContext;
      if (ctx != null && mounted) {
        unawaited(
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 350),
            alignment: 0.12,
          ),
        );
      }
    });
  }

  @override
  void didUpdateWidget(PlayerWatchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scrollToCurrent();
    if (widget.coverUrl != oldWidget.coverUrl) {
      _sampledCover = null;
      unawaited(_sampleCoverArt());
    }
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _playing) setState(() => _controlsVisible = false);
    });
  }

  void _poke() {
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      setState(() => _controlsVisible = true);
      if (_playing) _armHide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final w = size.width - 24;
    final videoH = (w * 9 / 16).clamp(0.0, size.height * 0.38);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: MediaQuery.paddingOf(context).top + videoH + 4,
            child: Stack(children: [_ambientBackdrop()]),
          ),
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _video(videoH),
                Expanded(child: _info()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Video ────────────────────────────────────────────────────────────────

  /// Both glows fade with scrolling; the lower one ends below Comments.
  Widget _ambientBackdrop({bool belowVideo = false}) {
    if (_glowRev <= 0) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<double>(
          valueListenable: _ambientOpacity,
          builder: (context, opacity, child) => Opacity(
            key: ValueKey(
              belowVideo ? 'ambient-info-opacity' : 'ambient-video-opacity',
            ),
            opacity: opacity,
            child: child,
          ),
          child: RepaintBoundary(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 900),
              child: SizedBox.expand(
                key: ValueKey<int>(_glowRev),
                child: DecoratedBox(
                  key: ValueKey(belowVideo ? 'ambient-info' : 'ambient-video'),
                  decoration: BoxDecoration(
                    gradient: belowVideo
                        ? LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: const [0, 0.35, 1],
                            colors: [
                              _glowBottom.withValues(alpha: 0.65),
                              _glowBottom.withValues(alpha: 0.35),
                              _glowBottom.withValues(alpha: 0),
                            ],
                          )
                        : RadialGradient(
                            center: Alignment.bottomCenter,
                            radius: 1.4,
                            colors: [
                              _glowBottom.withValues(alpha: 0.65),
                              _glowTop.withValues(alpha: 0.25),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Mini player card: inset box with rounded corners, not full-bleed. Same
  /// transparent scrims as the fullscreen player wash over it so the chrome
  /// stays legible on bright frames.
  Widget _video(double h) {
    return Padding(
      // SafeArea already clears the status bar — no double inset.
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          height: h,
          width: double.infinity,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.video,
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 64,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x59000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
              const Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: 110,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0x8C000000), Color(0x00000000)],
                      ),
                    ),
                  ),
                ),
              ),
              // Tap toggles the compact controls. Above the scrims, below
              // the bars.
              // No picture yet: hold the spinner. This latches on the first
              // frame, not the loading flag — progressive resolves lapse
              // the flag between mirrors, and taps must not dismiss it.
              if (widget.loading || !_frameUp)
                Center(
                  child: IgnorePointer(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: Colors.white),
                        const SizedBox(height: 10),
                        Text(
                          'Finding the best source…',
                          style: AppText.caption.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _poke,
                ),
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.arrow_back_rounded,
                            color: Colors.white,
                          ),
                          onPressed: widget.onBack,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          iconSize: 34,
                          icon: Icon(
                            Icons.skip_previous_rounded,
                            color: widget.hasPrevious
                                ? Colors.white
                                : Colors.white30,
                          ),
                          onPressed: widget.hasPrevious
                              ? widget.onPrevious
                              : null,
                        ),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: () {
                            widget.onTogglePlay();
                            _armHide();
                          },
                          child: Container(
                            width: 62,
                            height: 62,
                            decoration: BoxDecoration(
                              color: AppColors.accent,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              _playing
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 34,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          iconSize: 34,
                          icon: Icon(
                            Icons.skip_next_rounded,
                            color: widget.nextTitle != null
                                ? Colors.white
                                : Colors.white30,
                          ),
                          onPressed: widget.nextTitle != null
                              ? widget.onNext
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned(left: 0, right: 0, bottom: 0, child: _seekRow()),
            ],
          ),
        ),
      ),
    );
  }

  /// The only subtree that rebuilds every second.
  Widget _seekRow() {
    return AnimatedOpacity(
      opacity: _controlsVisible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: StreamBuilder<Duration?>(
          stream: widget.durationStream,
          initialData: widget.initialDuration,
          builder: (context, durSnap) {
            final total = durSnap.data ?? Duration.zero;
            return StreamBuilder<Duration>(
              stream: widget.positionStream,
              initialData: widget.initialPosition,
              builder: (context, posSnap) {
                final pos = posSnap.data ?? Duration.zero;
                final maxMs = total.inMilliseconds > 0
                    ? total.inMilliseconds.toDouble()
                    : 1.0;
                final value = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 4, 6),
                  child: Row(
                    children: [
                      Text(
                        formatWatchTime(pos),
                        style: AppText.caption.copyWith(color: Colors.white),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: AppColors.accent,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: AppColors.accent,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12,
                            ),
                            trackHeight: 3,
                          ),
                          child: Slider(
                            value: value,
                            max: maxMs,
                            onChanged: (v) => widget.onSeek(
                              Duration(milliseconds: v.round()),
                            ),
                          ),
                        ),
                      ),
                      Text(
                        formatWatchTime(total),
                        style: AppText.caption.copyWith(color: Colors.white70),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.fullscreen_rounded,
                          color: Colors.white,
                        ),
                        onPressed: widget.onFullscreen,
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  // ── Info ─────────────────────────────────────────────────────────────────

  Widget _info() {
    final l10n = context.l10n;
    return SingleChildScrollView(
      controller: _scroll,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              _ambientBackdrop(belowVideo: true),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.header.title,
                      style: AppText.headline.copyWith(
                        color: Colors.white,
                        fontSize: 20,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.header.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        widget.header.subtitle,
                        style: AppText.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    _actionRow(l10n),
                    if (widget.header.description != null) ...[
                      const SizedBox(height: 12),
                      _descriptionCard(),
                    ],
                    const SizedBox(height: 12),
                    _commentsRow(l10n),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: _episodeList(l10n),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(AppLocalizations l10n) {
    final serverLabel = widget.serverName?.trim().isNotEmpty ?? false
        ? 'Server · ${widget.serverName!.trim()}'
        : l10n.watchServer;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _chip(Icons.dns_outlined, serverLabel, widget.onServer),
          _chip(Icons.headphones_outlined, l10n.audio, widget.onAudio),
          _chip(Icons.subtitles_outlined, l10n.subtitles, widget.onSubtitles),
          _chip(Icons.more_horiz_rounded, l10n.more, widget.onMore),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppText.body.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _descriptionCard() {
    final l10n = context.l10n;
    return FrostedSurface(
      blur: false,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.header.description!,
              style: AppText.body.copyWith(color: AppColors.textSecondary),
              maxLines: _expanded ? null : 3,
              overflow: _expanded ? null : TextOverflow.ellipsis,
            ),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _expanded ? l10n.watchSeeLess : l10n.watchSeeMore,
                  style: AppText.body.copyWith(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _commentsRow(AppLocalizations l10n) {
    return GestureDetector(
      onTap: widget.onComments,
      child: FrostedSurface(
        blur: false,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                color: AppColors.accent,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.watchComments,
                      style: AppText.body.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      l10n.watchComingSoon,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  /// The episode list, inline — the list IS the up-next and the picker, so
  /// there is no separate Up Next card and no All-episodes button. Only what
  /// is still ahead shows; tapping opens that index.
  Widget _episodeList(AppLocalizations l10n) {
    if (widget.episodes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${l10n.watchEpisodes} (${widget.episodes.length})',
                style: AppText.body.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                l10n.watchAutoplay,
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
              Switch(
                value: widget.autoplay,
                activeThumbColor: AppColors.accent,
                onChanged: widget.onAutoplayChanged,
              ),
            ],
          ),
        ),
        for (final ep in widget.episodes) _episodeRow(ep),
      ],
    );
  }

  Widget _episodeRow(WatchPageEpisode ep) {
    final reason = (ep.unavailableReason ?? '').trim();
    final dead = reason.isNotEmpty;
    // Detail-screen row, unchanged: no card, no dividers — whitespace only.
    // The heading glows for the playing episode; dead rows dim with the
    // catalogue's own reason in the meta line.
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 116,
                  height: 65,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ep.thumb.isEmpty
                          ? Container(color: AppColors.surface2)
                          : CachedNetworkImage(
                              imageUrl: ep.thumb,
                              httpHeaders: widget.coverHeaders,
                              fit: BoxFit.cover,
                              memCacheWidth: 320,
                              errorWidget: (_, _, _) =>
                                  Container(color: AppColors.surface2),
                            ),
                      if (ep.current)
                        const Center(
                          child: Icon(
                            Icons.play_circle_filled_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ep.heading,
                      style: AppText.body.copyWith(
                        color: dead
                            ? AppColors.textTertiary
                            : ep.current
                            ? AppColors.accent
                            : Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (ep.meta.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          ep.meta,
                          style: AppText.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (ep.synopsis.isNotEmpty && !dead)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                ep.synopsis,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
    if (dead) return Opacity(opacity: 0.55, child: row);
    return GestureDetector(
      key: ep.current ? _currentKey : null,
      onTap: () => widget.onOpenEpisode(ep.index),
      behavior: HitTestBehavior.opaque,
      child: row,
    );
  }
}
