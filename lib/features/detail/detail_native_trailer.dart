// Native trailer preview keeps decoder setup off the Flutter UI isolate.
part of 'detail_screen.dart';

class _NativeHeroTrailer extends StatefulWidget {
  const _NativeHeroTrailer({
    required this.videoId,
    required this.collapsed,
    required this.placeholder,
    this.onTapFullscreen,
  });

  final String videoId;
  final bool collapsed;
  final Widget placeholder;
  final VoidCallback? onTapFullscreen;

  @override
  State<_NativeHeroTrailer> createState() => _NativeHeroTrailerState();
}

class _NativeHeroTrailerState extends State<_NativeHeroTrailer>
    with RouteAware {
  // Created lazily once a stream URL resolves — never before, so a failed
  // extraction never mounts an empty/black player.
  preview.VideoPlayerController? _player;
  VoidCallback? _playerListener;
  Completer<void>? _cancelOpen;

  // Keep the artwork visible until the first video frame is ready.
  bool _ready = false;
  // Extraction or playback failed → stay on the static cover.
  bool _errored = false;
  // Mute state — default muted; preserved across pause/resume.
  bool _muted = true;
  // User-facing play/pause intent (separate from the scroll-driven collapse
  // pause). Seeded from the "Autoplay trailer" setting: off → start paused.
  bool _paused = false;
  final TrailerRouteLifecycle _routeLifecycle = TrailerRouteLifecycle();
  Animation<double>? _routeAnimation;
  PlayerLifecycleGate _playerLifecycle = PlayerLifecycleGate();
  Future<void> _playerTeardown = Future<void>.value();
  String? _resolvedUrl;
  bool _resolvedUrlIsHd = false;

  @override
  void initState() {
    super.initState();
    _paused = !sl<PlaybackPrefs>().autoplayTrailer;
    _resolveAndOpen();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Listen for another screen covering/uncovering this page so the trailer
    // can pause instead of decoding video behind the player or a stacked title.
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
    final animation = route?.animation;
    if (!identical(animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_syncRouteStatus);
      _routeAnimation = animation;
      animation?.addStatusListener(_syncRouteStatus);
    }
    _syncRouteStatus(animation?.status ?? AnimationStatus.completed);
  }

  void _syncRouteStatus(AnimationStatus status) {
    final settled =
        status == AnimationStatus.completed &&
        ModalRoute.of(context)?.isCurrent != false;
    _routeLifecycle.setRouteSettled(settled);
    if (settled) {
      _restoreTrailer();
    } else {
      _player?.pause();
    }
  }

  // Another screen (the player, or a title tapped from this page) was pushed on
  // top — pause so a muted trailer isn't left decoding video out of sight.
  @override
  void didPushNext() {
    if (!_routeLifecycle.cover()) return;
    AppLogger.instance.log(
      '[detail-hero] covered trailer=${_player != null} ready=$_ready',
    );
    unawaited(_disposePlayer());
  }

  // Back on top — resume unless the user paused it, it's scrolled past, or it
  // failed. Mirrors the autostart gate so autoplay behaves exactly as before.
  @override
  void didPopNext() {
    if (!_routeLifecycle.uncover()) return;
    AppLogger.instance.log(
      '[detail-hero] uncovered trailer=${_player != null} ready=$_ready '
      'paused=$_paused errored=$_errored',
    );
    _restoreTrailer();
  }

  /// Extract a stream for the banner and start it muted + looping. HD toggle on
  /// → the 1080p video-only stream (the banner is muted, so no audio track is
  /// needed); otherwise the light muxed 360p. Falls back to 360p if HD
  /// extraction fails. On any failure we flip [_errored] and the cover stays.
  Future<void> _resolveAndOpen() async {
    final svc = sl<TrailerService>();
    final hdUrl = sl<PlaybackPrefs>().trailerHd
        ? (await svc.streamUrlHd(widget.videoId))?.video
        : null;
    final url = hdUrl ?? await svc.streamUrl(widget.videoId, low: true);
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      setState(() => _errored = true);
      return;
    }
    _resolvedUrl = url;
    _resolvedUrlIsHd = hdUrl != null;
    if (_routeLifecycle.canCreatePlayer) {
      await _openResolvedUrl(url, usedHd: _resolvedUrlIsHd);
    }
  }

  Future<void> _openResolvedUrl(String url, {required bool usedHd}) async {
    await _playerTeardown;
    await playerRouteTeardownBarrier.waitUntilIdle();
    if (!mounted ||
        !_routeLifecycle.canCreatePlayer ||
        widget.collapsed ||
        _errored ||
        _player != null ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    final player = preview.VideoPlayerController.networkUrl(Uri.parse(url));
    final lifecycle = PlayerLifecycleGate();
    _playerLifecycle = lifecycle;
    final openToken = lifecycle.beginOpen();
    final progressed = Completer<void>();
    final cancelled = _cancelOpen = Completer<void>();
    _player = player;
    _playerListener = () {
      if (!mounted || player != _player || !lifecycle.canContinue(openToken)) {
        return;
      }
      final value = player.value;
      if (value.hasError) {
        if (!_errored) setState(() => _errored = true);
      } else if (value.position > Duration.zero && !value.isBuffering) {
        if (!progressed.isCompleted) progressed.complete();
        if (!_ready) setState(() => _ready = true);
      }
    };
    player.addListener(_playerListener!);
    setState(() {});

    try {
      final opened = await lifecycle.runPlayerOpenSteps(openToken, [
        () {
          final initialized = player.initialize();
          return Future.any([
            usedHd
                ? initialized.timeout(const Duration(seconds: 7))
                : initialized,
            cancelled.future,
          ]);
        },
        () => player.setVolume(_muted ? 0 : 1),
        () => player.setLooping(true),
      ]);
      if (!opened || !mounted || player != _player) return;
      setState(() {});
      // Initialization prepares the native output without playing audible media.
      if (!_paused && !widget.collapsed && _routeLifecycle.canCreatePlayer) {
        await player.play();
        if (usedHd) {
          unawaited(_fallBackIfHdStalls(player, progressed.future));
        }
      }
    } catch (_) {
      if (!mounted || player != _player) return;
      if (usedHd) {
        await _fallBackToLow(player);
      } else {
        setState(() => _errored = true);
      }
    }
  }

  Future<void> _fallBackIfHdStalls(
    preview.VideoPlayerController player,
    Future<void> progressed,
  ) async {
    try {
      await progressed.timeout(const Duration(seconds: 7));
    } catch (_) {
      if (mounted && player == _player) await _fallBackToLow(player);
    }
  }

  Future<void> _fallBackToLow(preview.VideoPlayerController player) async {
    final low = await sl<TrailerService>().streamUrl(widget.videoId, low: true);
    if (!mounted || player != _player || low == null || low.isEmpty) return;
    _resolvedUrl = low;
    _resolvedUrlIsHd = false;
    await _disposePlayer();
    if (!mounted) return;
    _errored = false;
    await _openResolvedUrl(low, usedHd: false);
  }

  @override
  void didUpdateWidget(covariant _NativeHeroTrailer old) {
    super.didUpdateWidget(old);
    // Re-resolve from scratch if the id changes (different title).
    if (old.videoId != widget.videoId) {
      _resolvedUrl = null;
      _resolvedUrlIsHd = false;
      unawaited(_disposePlayer());
      _ready = false;
      _errored = false;
      _resolveAndOpen();
    }
    // Pause when scrolled past the hero; resume when it's expanded again —
    // but never resume a trailer the user deliberately paused.
    if (widget.collapsed != old.collapsed && !_errored) {
      if (widget.collapsed) {
        _player?.pause();
      } else {
        _restoreTrailer();
      }
    }
  }

  Future<void> _toggleMute() async {
    final player = _player;
    if (player == null) return;
    final next = !_muted;
    await player.setVolume(next ? 0 : 1);
    if (!mounted) return;
    setState(() => _muted = next);
  }

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null) return;
    final next = !_paused;
    setState(() => _paused = next);
    if (next) {
      await player.pause();
    } else if (!widget.collapsed) {
      await player.play();
    }
  }

  Future<void> _disposePlayer() {
    final player = _player;
    if (player == null) return _playerTeardown;

    final lifecycle = _playerLifecycle;
    final cancelled = _cancelOpen;
    _cancelOpen = null;
    if (_playerListener != null) player.removeListener(_playerListener!);
    _playerListener = null;
    _player = null;
    _ready = false;
    if (mounted && _routeLifecycle.canUpdateUi) setState(() {});
    AppLogger.instance.log('[detail-hero] retiring native trailer player');

    final teardownLease = playerRouteTeardownBarrier.acquire();
    _playerTeardown = lifecycle
        .close(
          stop: player.pause,
          dispose: () async {
            await player.dispose();
            AppLogger.instance.log(
              '[detail-hero] native trailer player retired',
            );
          },
        )
        .catchError((Object error) {
          AppLogger.instance.log(
            '[detail-hero] player teardown failed: $error',
          );
        })
        .whenComplete(teardownLease.release);
    // Invalidate the open token before waking a pending initialize step.
    cancelled?.complete();
    return _playerTeardown;
  }

  void _restoreTrailer() {
    if (!_routeLifecycle.canCreatePlayer || widget.collapsed || _errored) {
      return;
    }
    if (_player == null && _resolvedUrl != null) {
      unawaited(_openResolvedUrl(_resolvedUrl!, usedHd: _resolvedUrlIsHd));
    } else if (!_paused) {
      _player?.play();
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_syncRouteStatus);
    appRouteObserver.unsubscribe(this);
    _routeLifecycle.beginDispose();
    unawaited(_disposePlayer());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _player;
    final topInset = MediaQuery.of(context).padding.top;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Cover image underneath as placeholder + permanent fallback.
        widget.placeholder,
        // The native player, cover-fitted to fill the hero. Faded in once it's
        // actually playing; hidden entirely if extraction/playback errored.
        if (controller != null && !_errored)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _ready ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
                child: controller.value.isInitialized
                    ? FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox(
                          width: controller.value.size.width,
                          height: controller.value.size.height,
                          child: preview.VideoPlayer(controller),
                        ),
                      )
                    : const SizedBox.expand(),
              ),
            ),
          ),
        // Tap anywhere on the banner (outside the mute button) → fullscreen.
        if (widget.onTapFullscreen != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: widget.onTapFullscreen,
            ),
          ),
        // Controls — a horizontal row at top-right (clear of the top-left back
        // arrow and the bottom subtitles): play/pause then mute. Offset below
        // the status bar. Play/pause shows as soon as the player exists (so a
        // paused-start trailer can be started); mute only once it's actually
        // playing (mute is meaningless before that).
        if (controller != null && !_errored)
          Positioned(
            right: 14,
            top: topInset + 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HeroCircleButton(
                  icon: _paused
                      ? Icons.play_arrow_rounded
                      : Icons.pause_rounded,
                  onTap: _togglePlay,
                  semanticLabel: _paused ? 'Play trailer' : 'Pause trailer',
                ),
                if (_ready) ...[
                  const SizedBox(width: 8),
                  _HeroCircleButton(
                    icon: _muted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    onTap: _toggleMute,
                    semanticLabel: _muted ? 'Unmute' : 'Mute',
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
