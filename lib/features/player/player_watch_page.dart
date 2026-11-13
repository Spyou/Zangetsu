import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/frosted_surface.dart';
import '../detail/episode_filter.dart';
import '../../l10n/l10n.dart';
import 'watch_page_info.dart';
import 'watch_page_motion.dart';

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
    this.loadingStatus,
    this.bufferingStream,
    this.initialBuffering = false,
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
    this.seasons,
    this.selectedSeason,
    this.onSelectSeason,
    this.serverName,
    this.coverUrl,
    required this.onTogglePlay,
    required this.onSeek,
    this.onSeekBy,
    this.doubleTapSeconds = 10,
    this.onHoldSpeedChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onFullscreen,
    required this.onBack,
    required this.onServer,
    required this.onAudio,
    required this.onSubtitles,
    required this.onMore,
    required this.onOpenEpisode,
    this.onSetWatched,
    this.onPlayMirror,
    this.downloadButton,
    this.isEpisodeWatched,
    required this.onComments,
    required this.onAutoplayChanged,
    this.isMovie = false,
  });

  /// Uses movie wording while retaining the playable rows and their actions.
  final bool isMovie;

  /// The one video surface, built by the parent. This page only sizes it.
  final Widget video;
  final WatchPageHeader header;
  final Map<String, String>? coverHeaders;

  /// A resolve is in flight (episode switch or first load). The page stays —
  /// the spinner sits on the mini player instead of a black loader screen.
  final bool loading;
  final String? loadingStatus;
  final Stream<bool>? bufferingStream;
  final bool initialBuffering;

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

  /// Season chips above the list (detail-screen parity). Null/<=1 season
  /// hides the row; tapping filters the list in place, identity intact.
  final List<int>? seasons;
  final int? selectedSeason;
  final ValueChanged<int?>? onSelectSeason;

  final String? serverName;
  final String? coverUrl;

  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Duration>? onSeekBy;
  final int doubleTapSeconds;
  final ValueChanged<bool>? onHoldSpeedChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onFullscreen;
  final VoidCallback onBack;
  final VoidCallback onServer;
  final VoidCallback onAudio;
  final VoidCallback onSubtitles;
  final VoidCallback onMore;
  final ValueChanged<int> onOpenEpisode;
  final void Function(int, bool)? onSetWatched;
  final ValueChanged<int>? onPlayMirror;
  final Widget Function(WatchPageEpisode)? downloadButton;
  final bool Function(int)? isEpisodeWatched;
  final VoidCallback onComments;
  final ValueChanged<bool> onAutoplayChanged;

  @override
  State<PlayerWatchPage> createState() => _PlayerWatchPageState();
}

enum _WatchEpisodeAction { reverse, autoplay }

enum _WatchRowAction { watched, mirror }

class _PlayerWatchPageState extends State<PlayerWatchPage> {
  bool _controlsVisible = true;
  bool _expanded = false;
  Timer? _videoTapTimer;
  Timer? _videoSeekTimer;
  Timer? _videoFeedbackTimer;
  int _lastVideoTapSide = 0;
  int _pendingVideoSeek = 0;
  int _videoSeekSide = 0;
  int _videoSeekSeconds = 0;
  bool _showAfterVideoTap = false;
  bool _holdingSpeed = false;
  ValueChanged<bool>? _heldSpeedCallback;
  late bool _playing = widget.initialPlaying;
  StreamSubscription<bool>? _playingSub;
  Timer? _hideTimer;

  late final ScrollController _scroll;
  final ValueNotifier<double> _ambientOpacity = ValueNotifier(1);

  /// Row keys by real episode index, so scroll-to-current and jump land
  /// on the right row in list and grid alike.
  final Map<int, GlobalKey> _rowKeys = {};
  GlobalKey _rowKey(int index) => _rowKeys.putIfAbsent(index, GlobalKey.new);
  String _lastFingerprint = '';

  /// Display state (season comes from the parent): range page, reversed
  /// order, grid vs list. All presentational — tapped rows always carry the
  /// real episode index, so playback never sees this.
  int _range = 0;
  bool _reversed = false;
  bool _grid = false;

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
    _cancelVideoGestures();
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

  /// Display order after the reverse toggle.
  List<WatchPageEpisode> get _ordered =>
      _reversed ? widget.episodes.reversed.toList() : widget.episodes;

  int get _rangeCount => episodeRangeCount(_ordered.length);

  /// Visible page: the current range slice of the display order.
  List<WatchPageEpisode> get _paged {
    final d = _ordered;
    if (d.length <= kEpisodeRangeChunk) return d;
    final s = episodeRangeSlice(_range.clamp(0, _rangeCount - 1), d.length);
    return d.sublist(s.start, s.end);
  }

  String _rangeLabel(int i) {
    final s = episodeRangeSlice(i, _ordered.length);
    return '${s.start + 1}\u2013${s.end}';
  }

  String _fingerprint(List<WatchPageEpisode> eps) =>
      '${eps.length}:${eps.isEmpty ? -1 : eps.first.index}'
      ':${eps.isEmpty ? -1 : eps.last.index}';

  int? _revealedIndex;
  int _revealRequest = 0;

  /// Materialize the target within its page before scrolling it into view.
  void _revealEp(int realIndex, {bool force = false}) {
    if (!force && _revealedIndex == realIndex) return;
    final at = _ordered.indexWhere((e) => e.index == realIndex);
    if (at < 0) return;
    final want = at ~/ kEpisodeRangeChunk;
    if (want != _range) setState(() => _range = want);
    _revealedIndex = realIndex;
    final request = ++_revealRequest;
    void seek(int step) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || request != _revealRequest || !_scroll.hasClients) {
          return;
        }
        final ctx = _rowKey(realIndex).currentContext;
        if (ctx != null) {
          unawaited(
            Scrollable.ensureVisible(
              ctx,
              duration: const Duration(milliseconds: 250),
              alignment: 0.3,
            ),
          );
          return;
        }
        if (step > _paged.length + 1) return;
        final position = _scroll.position;
        final next = step == 0
            ? 0.0
            : (position.pixels + position.viewportDimension * 0.75).clamp(
                0.0,
                position.maxScrollExtent,
              );
        if (step > 0 && next == position.pixels) return;
        _scroll.jumpTo(next);
        seek(step + 1);
        WidgetsBinding.instance.scheduleFrame();
      });
    }

    seek(0);
  }

  void _scrollToCurrent() {
    final cur = _ordered.where((e) => e.current);
    if (cur.isEmpty) return;
    _revealEp(cur.first.index);
  }

  @override
  void didUpdateWidget(PlayerWatchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((!oldWidget.loading && widget.loading) ||
        oldWidget.header.title != widget.header.title ||
        oldWidget.header.subtitle != widget.header.subtitle ||
        (oldWidget.onHoldSpeedChanged != null &&
            widget.onHoldSpeedChanged == null)) {
      _cancelVideoGestures();
    }
    if (_fingerprint(widget.episodes) != _lastFingerprint) {
      _lastFingerprint = _fingerprint(widget.episodes);
      _revealedIndex = null;
      _revealRequest++;
    }
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

  void _flushVideoSeek() {
    _videoSeekTimer?.cancel();
    final seconds = _pendingVideoSeek;
    _pendingVideoSeek = 0;
    if (mounted && !widget.loading && seconds != 0) {
      widget.onSeekBy?.call(Duration(seconds: seconds));
    }
  }

  void _tapVideo(TapUpDetails details, double width) {
    if (widget.onSeekBy == null || widget.loading || !_frameUp) {
      _poke();
      return;
    }
    final side = details.localPosition.dx < width / 3
        ? -1
        : details.localPosition.dx > width * 2 / 3
        ? 1
        : 0;
    final repeated =
        side != 0 &&
        _lastVideoTapSide == side &&
        (_videoTapTimer?.isActive ?? false);
    _videoTapTimer?.cancel();
    _lastVideoTapSide = side;
    if (side == 0) {
      _showAfterVideoTap = false;
      _poke();
      return;
    }
    if (repeated) {
      _showAfterVideoTap = false;
      if (_videoSeekSide != side) {
        _flushVideoSeek();
        _videoSeekSeconds = 0;
      }
      _videoSeekSide = side;
      _videoSeekSeconds += widget.doubleTapSeconds;
      _pendingVideoSeek += side * widget.doubleTapSeconds;
      _videoSeekTimer?.cancel();
      _videoSeekTimer = Timer(
        const Duration(milliseconds: 350),
        _flushVideoSeek,
      );
      _videoFeedbackTimer?.cancel();
      _videoFeedbackTimer = Timer(const Duration(milliseconds: 800), () {
        if (mounted) {
          setState(() {
            _videoSeekSide = 0;
            _videoSeekSeconds = 0;
          });
        }
      });
      setState(() {});
    } else {
      _showAfterVideoTap = !_controlsVisible;
      if (_controlsVisible) _poke();
    }
    _videoTapTimer = Timer(const Duration(milliseconds: 280), () {
      _lastVideoTapSide = 0;
      if (mounted && _showAfterVideoTap && !_controlsVisible) _poke();
      _showAfterVideoTap = false;
    });
  }

  void _startSpeedHold() {
    if (widget.loading || !_frameUp || widget.onHoldSpeedChanged == null) {
      return;
    }
    _videoTapTimer?.cancel();
    _lastVideoTapSide = 0;
    _showAfterVideoTap = false;
    _heldSpeedCallback = widget.onHoldSpeedChanged;
    _heldSpeedCallback!(true);
    setState(() => _holdingSpeed = true);
  }

  void _endSpeedHold({bool rebuild = true}) {
    if (!_holdingSpeed) return;
    _holdingSpeed = false;
    _heldSpeedCallback?.call(false);
    _heldSpeedCallback = null;
    if (rebuild && mounted) setState(() {});
  }

  void _cancelVideoGestures() {
    _videoTapTimer?.cancel();
    _videoSeekTimer?.cancel();
    _videoFeedbackTimer?.cancel();
    _lastVideoTapSide = 0;
    _pendingVideoSeek = 0;
    _videoSeekSide = 0;
    _videoSeekSeconds = 0;
    _showAfterVideoTap = false;
    _endSpeedHold(rebuild: false);
  }

  Widget _videoGestureLabel(String text, {bool speed = false}) => DecoratedBox(
    decoration: BoxDecoration(
      color: speed ? Colors.black.withValues(alpha: 0.5) : Colors.black54,
      borderRadius: BorderRadius.circular(speed ? 13 : 14),
    ),
    child: Padding(
      padding: speed
          ? const EdgeInsets.fromLTRB(10, 6, 12, 6)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (speed) ...[
            const Icon(
              Icons.fast_forward_rounded,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 5),
          ],
          Text(
            text,
            style: AppText.caption.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontSize: speed ? 13.5 : null,
              height: speed ? 1.1 : null,
              letterSpacing: speed ? 0.3 : null,
            ),
          ),
        ],
      ),
    ),
  );

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
          key: const ValueKey('watch-video'),
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
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (details) =>
                        _tapVideo(details, constraints.maxWidth),
                    onLongPressStart: widget.onHoldSpeedChanged == null
                        ? null
                        : (_) => _startSpeedHold(),
                    onLongPressEnd: widget.onHoldSpeedChanged == null
                        ? null
                        : (_) => _endSpeedHold(),
                    onLongPressCancel: widget.onHoldSpeedChanged == null
                        ? null
                        : () => _endSpeedHold(),
                  ),
                ),
              ),
              Positioned.fill(
                key: const ValueKey('watch-seek-feedback'),
                child: IgnorePointer(
                  child: _videoSeekSide == 0
                      ? const SizedBox.shrink()
                      : Align(
                          alignment: Alignment(
                            _videoSeekSide < 0 ? -.65 : .65,
                            0,
                          ),
                          child: _videoGestureLabel(
                            '${_videoSeekSide < 0 ? '−' : '+'}${_videoSeekSeconds}s',
                          ),
                        ),
                ),
              ),
              Positioned(
                key: const ValueKey('watch-speed-feedback'),
                top: 12,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: _holdingSpeed
                      ? Center(child: _videoGestureLabel('2×', speed: true))
                      : const SizedBox.shrink(),
                ),
              ),
              Positioned(
                top: 6,
                left: 6,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: WatchPlayerButton(
                      key: const ValueKey('watch-back'),
                      icon: Icons.arrow_back_ios_new_rounded,
                      label: context.l10n.back,
                      size: 32,
                      iconSize: 18,
                      onTap: widget.onBack,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                bottom: 60,
                child: StreamBuilder<bool>(
                  stream: widget.bufferingStream,
                  initialData: widget.initialBuffering,
                  builder: (context, snapshot) {
                    final busy =
                        widget.loading || !_frameUp || snapshot.data == true;
                    return AnimatedOpacity(
                      opacity: _controlsVisible || busy ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !_controlsVisible && !busy,
                        child: Align(
                          alignment: const Alignment(0, 0.5),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Visibility(
                                visible: _controlsVisible,
                                maintainState: true,
                                maintainAnimation: true,
                                maintainSize: true,
                                child: WatchPlayerButton(
                                  icon: Icons.skip_previous_rounded,
                                  label: context.l10n.previousEpisode,
                                  size: 44,
                                  iconSize: 24,
                                  onTap: widget.hasPrevious
                                      ? widget.onPrevious
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 16),
                              WatchPlayerButton(
                                key: const ValueKey('watch-play'),
                                icon: _playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                label: busy
                                    ? context.l10n.loading
                                    : (_playing
                                          ? context.l10n.pause
                                          : context.l10n.play),
                                size: 56,
                                iconSize: 32,
                                busy: busy,
                                onTap: busy
                                    ? null
                                    : () {
                                        widget.onTogglePlay();
                                        _armHide();
                                      },
                              ),
                              const SizedBox(width: 16),
                              Visibility(
                                visible: _controlsVisible,
                                maintainState: true,
                                maintainAnimation: true,
                                maintainSize: true,
                                child: WatchPlayerButton(
                                  icon: Icons.skip_next_rounded,
                                  label: context.l10n.nextEpisode,
                                  size: 44,
                                  iconSize: 24,
                                  onTap: widget.nextTitle != null
                                      ? widget.onNext
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (widget.loadingStatus != null)
                Positioned(
                  top: 12,
                  left: 50,
                  right: 50,
                  child: IgnorePointer(
                    child: Text(
                      widget.loadingStatus!,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: Colors.white,
                        shadows: const [
                          Shadow(blurRadius: 6, color: Colors.black),
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
    return Directionality(
      textDirection: TextDirection.ltr,
      child: AnimatedOpacity(
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
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 24,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: AppColors.accent,
                              inactiveTrackColor: Colors.white.withValues(
                                alpha: 0.35,
                              ),
                              thumbColor: AppColors.accent,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 10,
                              ),
                              trackHeight: 3,
                              trackShape: const RectangularSliderTrackShape(),
                            ),
                            child: Slider(
                              padding: EdgeInsets.zero,
                              value: value,
                              max: maxMs,
                              onChanged: (v) => widget.onSeek(
                                Duration(milliseconds: v.round()),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 32,
                          child: Row(
                            children: [
                              Text(
                                '${formatWatchTime(pos)} / ${formatWatchTime(total)}',
                                style: AppText.caption.copyWith(
                                  color: Colors.white,
                                  fontSize: 13,
                                ),
                              ),
                              const Spacer(),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 32,
                                  height: 32,
                                ),
                                icon: const Icon(
                                  Icons.fullscreen_rounded,
                                  color: Colors.white,
                                  size: 24,
                                ),
                                onPressed: () {
                                  _flushVideoSeek();
                                  widget.onFullscreen();
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  // ── Info ─────────────────────────────────────────────────────────────────

  Widget _info() {
    final l10n = context.l10n;
    // CustomScrollView + SliverList: a 1000-episode title only builds the
    // rows on screen instead of inflating every thumbnail up front (that
    // eager Column is what froze One Piece on entry).
    return WatchPageChange(
      value: _grid,
      move: false,
      child: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: Stack(
              children: [
                _ambientBackdrop(belowVideo: true),
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: WatchPageChange(
                          value: widget.header.title,
                          child: Text(
                            widget.header.title,
                            style: AppText.headline.copyWith(
                              color: Colors.white,
                              fontSize: 20,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (widget.header.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: WatchPageChange(
                            value: widget.header.subtitle,
                            child: Text(
                              widget.header.subtitle,
                              style: AppText.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      _actionRow(l10n),
                      if (widget.header.description != null) ...[
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _descriptionCard(),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _commentsRow(l10n),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (widget.episodes.isNotEmpty)
            SliverToBoxAdapter(child: _episodesHeader(l10n)),
          if (_paged.isNotEmpty)
            _grid && !(widget.isMovie && widget.episodes.length == 1)
                ? SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                            childAspectRatio: 16 / 10,
                          ),
                      itemCount: _paged.length,
                      itemBuilder: (context, i) => _episodeTile(_paged[i]),
                    ),
                  )
                : SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    sliver: SliverList.builder(
                      itemCount: _paged.length,
                      itemBuilder: (context, i) => _episodeRow(_paged[i]),
                    ),
                  ),
        ],
      ),
    );
  }

  Widget _actionRow(AppLocalizations l10n) {
    final serverLabel = widget.serverName?.trim().isNotEmpty ?? false
        ? 'Server · ${widget.serverName!.trim().split(RegExp(r"[\r\n]")).first}'
        : l10n.watchServer;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
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
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: WatchPagePress(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(999),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.58,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
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

  Widget _descriptionCard() {
    final l10n = context.l10n;
    return FrostedSurface(
      blur: false,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedSize(
        duration: watchPageMotionEnabled(context)
            ? const Duration(milliseconds: 220)
            : Duration.zero,
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WatchPageChange(
                value: widget.header.description,
                child: Text(
                  widget.header.description!,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                  maxLines: _expanded ? null : 3,
                  overflow: _expanded ? null : TextOverflow.ellipsis,
                ),
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

  /// The episode list header, mirroring the detail screen: a season
  /// dropdown pill on the left, jump / reverse / grid actions on the right,
  /// and a horizontal 1-50 style range row below for long titles. The
  /// scrolling rows below ARE the up-next and the picker.
  Widget _episodesHeader(AppLocalizations l10n) {
    final multiSeason = widget.seasons != null && widget.seasons!.length > 1;
    final showRanges = _ordered.length > kEpisodeRangeChunk;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                widget.isMovie
                    ? l10n.movie
                    : '${l10n.watchEpisodes} (${widget.episodes.length})',
                style: AppText.body.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (!widget.isMovie) ...[
                _roundBtn(
                  Icons.search_rounded,
                  l10n.findEpisode,
                  () => _openJumpDialog(l10n),
                ),
                const SizedBox(width: 8),
              ],
              if (!widget.isMovie || widget.episodes.length > 1) ...[
                _roundBtn(
                  _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                  _grid ? l10n.listView : l10n.gridView,
                  () => setState(() => _grid = !_grid),
                ),
                const SizedBox(width: 8),
              ],
              _moreMenu(l10n),
            ],
          ),
          if (multiSeason || showRanges)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  if (multiSeason) _seasonPill(l10n),
                  if (multiSeason && showRanges) const SizedBox(width: 8),
                  if (showRanges)
                    Expanded(
                      child: SizedBox(
                        height: 32,
                        child: ListView.separated(
                          key: const ValueKey('watch_ranges'),
                          scrollDirection: Axis.horizontal,
                          padding: EdgeInsets.zero,
                          clipBehavior: Clip.none,
                          itemCount: _rangeCount,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final sel = i == _range.clamp(0, _rangeCount - 1);
                            return Material(
                              animationDuration: watchPageMotionEnabled(context)
                                  ? const Duration(milliseconds: 180)
                                  : Duration.zero,
                              color: sel
                                  ? AppColors.accent
                                  : AppColors.surface2,
                              borderRadius: BorderRadius.circular(999),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => setState(() {
                                  _revealRequest++;
                                  _range = i;
                                }),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Center(
                                    child: Text(
                                      _rangeLabel(i),
                                      style: AppText.caption.copyWith(
                                        color: sel
                                            ? Colors.white
                                            : AppColors.textSecondary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Round action button, same shape language as the detail header.
  Widget _roundBtn(IconData icon, String semantic, VoidCallback onTap) {
    return Semantics(
      button: true,
      label: semantic,
      child: Material(
        color: AppColors.surface2,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: AppColors.textPrimary, size: 20),
          ),
        ),
      ),
    );
  }

  Widget _moreMenu(AppLocalizations l10n) {
    return PopupMenuButton<_WatchEpisodeAction>(
      tooltip: l10n.more,
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        backgroundColor: AppColors.surface2,
        fixedSize: const Size.square(36),
        minimumSize: const Size.square(36),
        maximumSize: const Size.square(36),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const CircleBorder(),
      ),
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (action) {
        if (action == _WatchEpisodeAction.autoplay) {
          widget.onAutoplayChanged(!widget.autoplay);
          return;
        }
        setState(() {
          _reversed = !_reversed;
          _range = 0;
          _scrollToCurrent();
        });
      },
      itemBuilder: (_) => [
        _episodeMenuItem(
          _WatchEpisodeAction.reverse,
          Icons.swap_vert_rounded,
          l10n.watchReverseOrder,
          _reversed,
        ),
        _episodeMenuItem(
          _WatchEpisodeAction.autoplay,
          Icons.play_circle_outline_rounded,
          l10n.watchAutoplay,
          widget.autoplay,
        ),
      ],
    );
  }

  PopupMenuItem<_WatchEpisodeAction> _episodeMenuItem(
    _WatchEpisodeAction action,
    IconData icon,
    String label,
    bool checked,
  ) => PopupMenuItem(
    value: action,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 20,
          height: 20,
          child: checked ? const Icon(Icons.check_rounded, size: 18) : null,
        ),
      ],
    ),
  );

  /// Season dropdown pill. Opens the same kind of bottom sheet the detail
  /// screen uses; picking filters the inline list in place.
  Widget _seasonPill(AppLocalizations l10n) {
    final selected = widget.selectedSeason ?? widget.seasons!.first;
    final label = '${l10n.season} $selected';
    return Material(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openSeasonSheet(l10n),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              WatchPageChange(
                value: label,
                child: Text(label, style: AppText.headline),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: AppColors.textPrimary,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSeasonSheet(AppLocalizations l10n) async {
    final seasons = widget.seasons ?? const <int>[];
    final picked = await showModalBottomSheet<int?>(
      context: context,
      backgroundColor: AppColors.surface,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      sheetAnimationStyle: watchPageMotionEnabled(context)
          ? const AnimationStyle(
              duration: Duration(milliseconds: 200),
              reverseDuration: Duration(milliseconds: 180),
            )
          : (MediaQuery.disableAnimationsOf(context)
                ? AnimationStyle.noAnimation
                : null),
      builder: (ctx) => WatchPageMenuEntrance(
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
                child: Text(l10n.season, style: AppText.title),
              ),
              const Divider(height: 1, color: AppColors.hairline),
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.6,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.only(bottom: 12),
                    children: [
                      for (final s in seasons)
                        _seasonSheetRow(
                          ctx,
                          label: '${l10n.season} $s',
                          selected: widget.selectedSeason == s,
                          onTap: () => Navigator.pop(ctx, s),
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
    if (picked != widget.selectedSeason ||
        (picked == null && widget.selectedSeason != null)) {
      widget.onSelectSeason?.call(picked);
    }
  }

  Widget _seasonSheetRow(
    BuildContext ctx, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: AppText.body.copyWith(
                  color: selected ? AppColors.accent : AppColors.textPrimary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            if (selected) Icon(Icons.check_rounded, color: AppColors.accent),
          ],
        ),
      ),
    );
  }

  /// Jump to an episode number: switches to its range page, then scrolls
  /// the row into view. Unknown numbers dismiss quietly.
  Future<void> _openJumpDialog(AppLocalizations l10n) async {
    final controller = TextEditingController();
    final go = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.jumpToEpisode),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.episodeNumber),
          onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v.trim())),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, int.tryParse(controller.text.trim())),
            child: Text(l10n.go),
          ),
        ],
      ),
    );
    if (go == null || !mounted) return;
    final at = widget.episodes.indexWhere((e) => e.number?.toInt() == go);
    final target = at >= 0 ? at : go - 1;
    if (target < 0 || target >= widget.episodes.length) return;
    _revealEp(widget.episodes[target].index, force: true);
  }

  Future<void> _episodeMenu(WatchPageEpisode ep) async {
    final watched = widget.isEpisodeWatched?.call(ep.index) ?? ep.watched;
    final action = await showModalBottomSheet<_WatchRowAction>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => WatchPageMenuEntrance(
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  ep.heading,
                  style: AppText.headline,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.onSetWatched != null)
                ListTile(
                  leading: Icon(
                    watched
                        ? Icons.remove_done_rounded
                        : Icons.check_circle_outline_rounded,
                  ),
                  title: Text(
                    watched ? 'Mark as unwatched' : 'Mark as watched',
                  ),
                  onTap: () => Navigator.pop(ctx, _WatchRowAction.watched),
                ),
              if (widget.onPlayMirror != null &&
                  (ep.unavailableReason ?? '').trim().isEmpty)
                ListTile(
                  leading: const Icon(Icons.swap_horiz_rounded),
                  title: Text(context.l10n.playMirror),
                  onTap: () => Navigator.pop(ctx, _WatchRowAction.mirror),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == _WatchRowAction.watched) {
      widget.onSetWatched?.call(ep.index, !watched);
    }
    if (action == _WatchRowAction.mirror) widget.onPlayMirror?.call(ep.index);
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
                      if (ep.watched && !ep.current)
                        const Align(
                          alignment: Alignment.bottomRight,
                          child: Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.check_circle_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
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
                    AnimatedDefaultTextStyle(
                      duration: watchPageMotionEnabled(context)
                          ? const Duration(milliseconds: 180)
                          : Duration.zero,
                      style: AppText.body.copyWith(
                        color: dead
                            ? AppColors.textTertiary
                            : ep.current
                            ? AppColors.accent
                            : ep.watched
                            ? AppColors.textSecondary
                            : Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                      child: Text(
                        ep.heading,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
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
              if (!dead && widget.downloadButton != null) ...[
                const SizedBox(width: 8),
                widget.downloadButton!(ep),
              ],
            ],
          ),
          if (ep.synopsis.isNotEmpty && !dead)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                ep.synopsis,
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontStyle: FontStyle.italic,
                  height: 1.4,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
    final interactive = Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: _rowKey(ep.index),
        onTap: dead ? null : () => widget.onOpenEpisode(ep.index),
        onLongPress: widget.onSetWatched == null && widget.onPlayMirror == null
            ? null
            : () => _episodeMenu(ep),
        splashColor: AppColors.accentSoft,
        highlightColor: AppColors.surface,
        child: row,
      ),
    );
    return dead ? Opacity(opacity: .55, child: interactive) : interactive;
  }

  Widget _episodeTile(WatchPageEpisode ep) {
    final reason = (ep.unavailableReason ?? '').trim();
    final dead = reason.isNotEmpty;
    final label = ep.number != null
        ? '${ep.number!.toInt()}'
        : '${ep.index + 1}';
    final tile = AnimatedContainer(
      key: _rowKey(ep.index),
      duration: watchPageMotionEnabled(context)
          ? const Duration(milliseconds: 180)
          : Duration.zero,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: ep.current
            ? AppColors.accent.withValues(alpha: 0.16)
            : AppColors.surface2,
        borderRadius: BorderRadius.circular(12),
        border: ep.current ? Border.all(color: AppColors.accent) : null,
      ),
      alignment: Alignment.center,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          splashColor: AppColors.accentSoft,
          highlightColor: AppColors.surface,
          onTap: dead ? null : () => widget.onOpenEpisode(ep.index),
          onLongPress:
              widget.onSetWatched == null && widget.onPlayMirror == null
              ? null
              : () => _episodeMenu(ep),
          child: Center(
            child: Text(
              label,
              style: AppText.headline.copyWith(
                color: dead
                    ? AppColors.textTertiary
                    : ep.current
                    ? AppColors.accent
                    : ep.watched
                    ? AppColors.textSecondary
                    : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
    return dead ? Opacity(opacity: .55, child: tile) : tile;
  }
}

/// Shared portrait control so resolving and playing use the same chrome.
class WatchPlayerButton extends StatelessWidget {
  const WatchPlayerButton({
    super.key,
    required this.icon,
    required this.label,
    required this.size,
    required this.iconSize,
    required this.onTap,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final double size;
  final double iconSize;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: !busy,
      enabled: onTap != null && !busy,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: AbsorbPointer(
          absorbing: busy,
          child: InkWell(
            onTap: busy ? null : onTap,
            child: SizedBox.square(
              dimension: size < 48 ? 48 : size,
              child: Center(
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Center(
                    child: busy
                        ? const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : Icon(
                            icon,
                            size: iconSize,
                            color: onTap != null
                                ? Colors.white
                                : Colors.white30,
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
}
