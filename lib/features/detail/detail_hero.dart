// Hero header: backdrop, poster, trailer playback and the action buttons.
part of 'detail_screen.dart';


// ─────────────────────────────────────────────────────────────────────────────
// Hero — full-width backdrop with a portrait poster overlapping the bottom-right
// and a back arrow over the top-left.
// ─────────────────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  const _Hero({
    required this.coverUrl,
    required this.coverHeaders,
    required this.hasCover,
    this.trailerId,
    this.collapsed = false,
    this.onTapFullscreen,
  });

  final String coverUrl;
  final Map<String, String>? coverHeaders;
  final bool hasCover;

  /// Resolved YouTube id, or null while still loading / when none exists.
  final String? trailerId;

  /// True once the hero has scrolled past — the trailer pauses while collapsed.
  final bool collapsed;

  /// Opens the fullscreen trailer when the banner is tapped. Null disables it.
  final VoidCallback? onTapFullscreen;

  /// The static cover backdrop — used as the base layer when there's no
  /// trailer, and as the placeholder/fallback underneath the player.
  Widget _coverBackdrop() {
    if (!hasCover) return ColoredBox(color: AppColors.surface2);
    // Aniyomi/Mihon path: when the x-ani-src / x-mihon-src marker is present,
    // fetch image bytes through the source's own OkHttpClient (which carries the
    // CF session) instead of CachedNetworkImage which cannot pass Cloudflare.
    final aniSrcId = coverHeaders?['x-ani-src'];
    final mihonSrcId = coverHeaders?['x-mihon-src'];
    if (aniSrcId != null || mihonSrcId != null) {
      return Image(
        // Resize to the backdrop's memCacheWidth (matches the non-native path)
        // so a full-res cover doesn't sit in the image cache.
        image: ResizeImage(
          aniSrcId != null
              ? AniyomiImage(int.parse(aniSrcId), coverUrl)
              : MihonImage(int.parse(mihonSrcId!), coverUrl),
          width: 800,
        ),
        fit: BoxFit.cover,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : ColoredBox(color: AppColors.surface2),
        errorBuilder: (context, error, stackTrace) =>
            ColoredBox(color: AppColors.surface2),
      );
    }
    return CachedNetworkImage(
      imageUrl: coverUrl,
      httpHeaders: coverHeaders,
      fit: BoxFit.cover,
      memCacheWidth: 800,
      placeholder: (c, u) => ColoredBox(color: AppColors.surface2),
      errorWidget: (c, u, e) => ColoredBox(color: AppColors.surface2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final id = trailerId;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Backdrop: autoplaying trailer once an id resolves, else the cover
        // image. The cover image always sits underneath as placeholder/fallback
        // so there's never a blank/black flash.
        (id != null && id.isNotEmpty)
            ? _HeroTrailer(
                videoId: id,
                collapsed: collapsed,
                onTapFullscreen: onTapFullscreen,
                placeholder: _coverBackdrop(),
              )
            : _coverBackdrop(),
        // Gradients render OVER the video for title readability.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.topScrim),
          ),
        ),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.scrim),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _HeroTrailer — the autoplaying, muted, looping trailer that becomes the hero
// backdrop once a YouTube id resolves (Netflix-style). The trailer is a DIRECT
// muxed stream (extracted by youtube_explode_dart) played natively via
// media_kit — NO iframe, NO YouTube chrome (no related-videos / endscreen /
// branding). The static cover image stays visible underneath until the first
// frame is painted, so there's never a blank/black flash; if extraction or
// playback fails we keep showing the cover.
//
// • Muted + autoplay + loops the single media + cover-fit (BoxFit.cover).
// • A bottom-left mute toggle (default muted); the choice survives pause/resume.
// • Pauses when [collapsed] (scrolled past) and on dispose; the Player is
//   created only once a stream URL resolves and is disposed in dispose().
// • Tapping the banner (outside the mute button) opens the fullscreen trailer.
// ─────────────────────────────────────────────────────────────────────────────

class _HeroTrailer extends StatefulWidget {
  const _HeroTrailer({
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
  State<_HeroTrailer> createState() => _HeroTrailerState();
}

class _HeroTrailerState extends State<_HeroTrailer> with RouteAware {
  // Created lazily once a stream URL resolves — never before, so a failed
  // extraction never mounts an empty/black player.
  Player? _player;
  VideoController? _videoController;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;

  // Cross-fade the player in once it's actually playing so the cover never
  // blanks.
  bool _ready = false;
  // Extraction or playback failed → stay on the static cover.
  bool _errored = false;
  // Mute state — default muted; preserved across pause/resume.
  bool _muted = true;
  // User-facing play/pause intent (separate from the scroll-driven collapse
  // pause). Seeded from the "Autoplay trailer" setting: off → start paused.
  bool _paused = false;
  // True while another screen is stacked on top (player / another title). Gates
  // autostart too, so a trailer that resolves after the page got covered stays
  // put instead of playing out of sight.
  bool _covered = false;

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
  }

  // Another screen (the player, or a title tapped from this page) was pushed on
  // top — pause so a muted trailer isn't left decoding video out of sight.
  @override
  void didPushNext() {
    _covered = true;
    _player?.pause();
  }

  // Back on top — resume unless the user paused it, it's scrolled past, or it
  // failed. Mirrors the autostart gate so autoplay behaves exactly as before.
  @override
  void didPopNext() {
    _covered = false;
    if (!_paused && !widget.collapsed && !_errored) _player?.play();
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
    final player = Player();
    final controller = VideoController(player);
    _player = player;
    _videoController = controller;
    // Mount the Video widget NOW (build renders it once _videoController != null),
    // so media_kit's video output/texture exists BEFORE we play. Otherwise libmpv
    // (esp. on iOS) can sit paused until a relayout/tap and the trailer never
    // auto-starts — that was the "have to tap the banner to start it" bug.
    if (mounted) setState(() {});

    await player.setVolume(_muted ? 0 : 100);
    // Loop the single trailer media (Netflix-style).
    await player.setPlaylistMode(PlaylistMode.single);

    // Reveal the player on the first "playing" event so we cross-fade in
    // rather than showing a black first frame.
    _playingSub = player.stream.playing.listen((playing) {
      if (!mounted) return;
      if (playing && !_ready) setState(() => _ready = true);
    });
    // Belt-and-braces loop: also restart on completion (covers engines where
    // PlaylistMode.single doesn't auto-restart a single media).
    _completedSub = player.stream.completed.listen((done) {
      if (done && mounted && !widget.collapsed && !_paused && !_covered) {
        _player?.seek(Duration.zero);
        _player?.play();
      }
    });

    try {
      // Open WITHOUT relying solely on open(play:) — some engines/platforms
      // don't honor the autoplay flag until the first user interaction. Open
      // paused, then explicitly play() the moment the media is loaded and the
      // widget is still mounted, so the trailer starts on its own with no touch.
      final autostart = !_paused && !widget.collapsed && !_covered;
      await player.open(Media(url), play: autostart);
      if (!mounted) return;
      // Autostart only when the hero is on-screen AND the user hasn't paused
      // (via the button or the "Autoplay trailer" setting being off). If it's
      // paused or already scrolled past, stay put — the play button and the
      // collapsed handler in didUpdateWidget start it later.
      if (autostart) {
        await player.play();
        // Best-effort HD: 1080p is a throttled adaptive stream that can stall.
        // If it doesn't actually start rolling, swap to the reliable 360p muxed
        // stream so the banner never sits frozen on a single frame.
        if (hdUrl != null) unawaited(_fallBackIfHdStalls(player));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _errored = true);
    }
  }

  /// Watchdog for the opt-in HD banner: if playback hasn't progressed within a
  /// few seconds (YouTube throttled the 1080p stream), re-open with the light
  /// 360p muxed stream. No-op if HD started fine.
  Future<void> _fallBackIfHdStalls(Player player) async {
    try {
      await player.stream.position
          .firstWhere((p) => p > Duration.zero)
          .timeout(const Duration(seconds: 7));
    } catch (_) {
      if (!mounted || player != _player) return;
      final low = await sl<TrailerService>().streamUrl(widget.videoId, low: true);
      if (!mounted || player != _player || low == null || low.isEmpty) return;
      try {
        final autostart = !_paused && !widget.collapsed && !_covered;
        await player.open(Media(low), play: autostart);
        if (autostart) await player.play();
      } catch (_) {/* leave the cover as the backdrop */}
    }
  }

  @override
  void didUpdateWidget(covariant _HeroTrailer old) {
    super.didUpdateWidget(old);
    // Re-resolve from scratch if the id changes (different title).
    if (old.videoId != widget.videoId) {
      _disposePlayer();
      _ready = false;
      _errored = false;
      _resolveAndOpen();
    }
    // Pause when scrolled past the hero; resume when it's expanded again —
    // but never resume a trailer the user deliberately paused.
    if (widget.collapsed != old.collapsed && !_errored) {
      if (widget.collapsed) {
        _player?.pause();
      } else if (!_paused) {
        _player?.play();
      }
    }
  }

  Future<void> _toggleMute() async {
    final player = _player;
    if (player == null) return;
    final next = !_muted;
    await player.setVolume(next ? 0 : 100);
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

  void _disposePlayer() {
    _playingSub?.cancel();
    _completedSub?.cancel();
    _playingSub = null;
    _completedSub = null;
    _videoController = null;
    _player?.dispose();
    _player = null;
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _disposePlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _videoController;
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
                child: Video(
                  controller: controller,
                  controls: NoVideoControls,
                  fit: BoxFit.cover,
                  fill: Colors.transparent,
                ),
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

// Small translucent circular icon button for the hero trailer controls
// (mute/unmute and play/pause).
class _HeroCircleButton extends StatelessWidget {
  const _HeroCircleButton({
    required this.icon,
    required this.onTap,
    this.semanticLabel,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    // The visible circle is 36dp, but the tap target is a full 48dp. Using an
    // opaque GestureDetector (NOT an InkWell, which defers hit-testing to its
    // painted child) so the whole 48dp square absorbs the tap — otherwise taps
    // in the ring around the icon fall through to the banner's fullscreen
    // gesture behind, which is what made the buttons feel unresponsive.
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0x66000000),
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(8),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-width WHITE Play button (black label) — Netflix-style. Rounded ~8.
// ─────────────────────────────────────────────────────────────────────────────

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.label,
    this.onPressed,
    this.icon = Icons.play_arrow_rounded,
  });
  final String label;
  final VoidCallback? onPressed;

  /// Reading types (manga/novel) show a book icon instead of the play glyph.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.black, size: 26),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: AppText.button.copyWith(color: Colors.black),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-width GRAY Download button (surface2, white label) — Netflix-style.
// Downloads aren't implemented yet, so it just snacks.
// ─────────────────────────────────────────────────────────────────────────────

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: SizedBox(
          height: 52,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.file_download_outlined,
                color: Colors.white,
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(label, style: AppText.button.copyWith(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}
