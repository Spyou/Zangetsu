// The controls laid over the video: top bar, centre transport, bottom block.
part of 'player_screen.dart';

class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.controller,
    required this.state,
    required this.showTitle,
    required this.duration,
    required this.onDurationChanged,
    required this.onInteract,
    required this.onBack,
    required this.onSpeed,
    required this.onAudioSubs,
    required this.onQuality,
    required this.onSources,
    required this.onLock,
    required this.onSettings,
    required this.barConfig,
    required this.onZoom,
    required this.zoomLabel,
    required this.onPrev,
    required this.onSleep,
    required this.sleepActive,
    required this.decoderLabel,
    required this.onDecoder,
    required this.onEpisodes,
    required this.megaSkipEnabled,
    required this.megaSkipSeconds,
    required this.onMegaSkip,
    this.onPip,
    this.onChat,
    this.onInfo,
    this.infoOpen = false,
    this.showQuality = false,
    required this.onScreenshot,
    required this.onEnhance,
    required this.enhanceActive,
    required this.onColorProfile,
    this.visible = true,
  });

  final PlayerCubit controller;
  final PlayerState state;
  final String? showTitle;
  final Duration duration;
  final ValueChanged<Duration> onDurationChanged;
  final VoidCallback onInteract;
  final VoidCallback onBack;
  final VoidCallback onSpeed;
  final VoidCallback onAudioSubs;
  final VoidCallback onQuality;
  final VoidCallback onSources;
  final VoidCallback onLock;
  final VoidCallback onSettings;

  /// The user's control arrangement — which bar each control sits on, in what
  /// order. Drives both bars; anything not placed is reachable via ⋮ More.
  final PlayerControlsConfig barConfig;

  final VoidCallback onZoom;
  final String zoomLabel;
  final VoidCallback? onPrev; // null = no previous episode
  final VoidCallback onSleep;
  final bool sleepActive;
  final String decoderLabel; // current decoder short label (HW/HW+/SW/AUTO)
  final VoidCallback onDecoder; // opens the in-player decoder picker
  final VoidCallback? onEpisodes; // null = single episode (no picker)
  final bool megaSkipEnabled; // MegaSkip pill above the seek bar
  final int megaSkipSeconds;
  final VoidCallback onMegaSkip;
  final VoidCallback? onPip; // null = PiP unsupported (hide the button)
  final VoidCallback? onChat; // in-room chat toggle (null = no active room)
  final VoidCallback? onInfo; // toggle the info panel (null = no fields picked)
  final bool infoOpen; // whether the info panel is currently shown
  final bool showQuality; // plain quality text on the top-bar right (with controls)
  final VoidCallback onScreenshot; // grab the current frame → gallery
  final VoidCallback onEnhance; // opens the video-enhancement (upscaler) picker
  final bool enhanceActive; // an upscaling preset is currently on
  final VoidCallback onColorProfile; // opens the colour-profile picker
  final bool visible; // drives the bars' slide-in (top drops, bottom rises)

  /// Overflow panel that slides in from the RIGHT (like the episodes panel) —
  /// holds the occasional actions so the control bars stay clean.
  void _showMore(BuildContext context) {
    onInteract();
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'More',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (ctx, _, _) {
        // Same width and surface as the episodes panel — this slides in from
        // the same edge with the same motion, so looking different was just
        // two panels wearing two skins. 40% was wider than it needed to be
        // for a short list of labels, too.
        final w = (MediaQuery.of(ctx).size.width * 0.33).clamp(250.0, 360.0);
        return Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: FrostedSurface(
              blur: true,
              opacity: 0.88,
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(20),
              ),
              // Left inset dropped for the same reason as the episodes panel:
              // this is pinned to the RIGHT edge, so padding it away from a
              // cutout on the opposite side just eats its width.
              child: SafeArea(
                left: false,
                child: SizedBox(
                  width: w,
                  height: double.infinity,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 13, 8, 9),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('More', style: AppText.title),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.close_rounded,
                                color: AppColors.textSecondary,
                              ),
                              tooltip: 'Close',
                              onPressed: () => Navigator.of(ctx).pop(),
                            ),
                          ],
                        ),
                      ),
                      const Divider(color: AppColors.hairline, height: 1),
                      const SizedBox(height: 4),
                    _MoreRow(
                      icon: Icons.memory_rounded,
                      label: 'Decoder · $decoderLabel',
                      onTap: () {
                        Navigator.pop(ctx);
                        onDecoder();
                      },
                    ),
                    _MoreRow(
                      icon: enhanceActive
                          ? Icons.auto_awesome_rounded
                          : Icons.auto_awesome_outlined,
                      label: 'Anime4K Enhancement',
                      onTap: () {
                        Navigator.pop(ctx);
                        onEnhance();
                      },
                    ),
                    _MoreRow(
                      icon: Icons.palette_outlined,
                      label: 'Colour',
                      onTap: () {
                        Navigator.pop(ctx);
                        onColorProfile();
                      },
                    ),
                    _MoreRow(
                      icon: Icons.photo_camera_rounded,
                      label: 'Snapshot',
                      onTap: () {
                        Navigator.pop(ctx);
                        onScreenshot();
                      },
                    ),
                    _MoreRow(
                      icon: sleepActive
                          ? Icons.bedtime_rounded
                          : Icons.bedtime_outlined,
                      label: 'Sleep timer',
                      onTap: () {
                        Navigator.pop(ctx);
                        onSleep();
                      },
                    ),
                      if (onPip != null)
                        _MoreRow(
                          icon: Icons.picture_in_picture_alt_rounded,
                          label: 'Picture-in-picture',
                          onTap: () {
                            Navigator.pop(ctx);
                            onPip!();
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (ctx, anim, _, child) => SlideTransition(
        position: Tween(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
        child: child,
      ),
    );
  }

  /// Whether [id] sits on any bar. Used so a control that's already placed
  /// doesn't also get drawn by one of the player's own conditional buttons.
  bool _placedAnywhere(String id) =>
      barConfig.slotOf(id) != ControlSlot.hidden;

  /// Top-bar versions of the arrangeable controls. Plain [IconButton]s rather
  /// than the bottom bar's chips, so anything moved up here matches the row
  /// it lands in instead of importing the bottom bar's look.
  List<Widget> _topButtons(BuildContext context, List<String> ids) {
    final out = <Widget>[];
    for (final id in ids) {
      switch (id) {
        case 'cast':
          // Android only, and only where the Cast framework is actually
          // supported — the setting decides placement, not availability.
          if (Platform.isAndroid) {
            out.add(AnimatedBuilder(
              animation: sl<CastController>(),
              builder: (context, _) {
                final castCtrl = sl<CastController>();
                if (!castCtrl.castSupported) return const SizedBox.shrink();
                return IconButton(
                  icon: Icon(
                    castCtrl.state == CastState.connected
                        ? Icons.cast_connected
                        : Icons.cast,
                    color: Colors.white,
                  ),
                  tooltip: 'Cast',
                  onPressed: () => castCtrl.pickDevice(),
                );
              },
            ));
          }
        case 'info':
          if (onInfo != null) {
            out.add(IconButton(
              icon: Icon(
                Icons.info_outline_rounded,
                color: infoOpen ? AppColors.accent : Colors.white,
              ),
              tooltip: 'Playback stats',
              onPressed: onInfo,
            ));
          }
        default:
          final spec = _specFor(context, id);
          if (spec != null) {
            out.add(IconButton(
              icon: Icon(spec.$1, color: Colors.white),
              tooltip: spec.$2,
              onPressed: spec.$3,
            ));
          }
      }
    }
    return out;
  }

  /// Icon, tooltip and action for the controls that render the same wherever
  /// they're placed. Returns null when the control isn't available right now
  /// (no second quality to pick, a single-episode item, no PiP support).
  (IconData, String, VoidCallback)? _specFor(BuildContext context, String id) {
    final c = controller;
    switch (id) {
      case 'speed':
        return (Icons.speed_rounded, 'Playback speed', onSpeed);
      case 'tracks':
        return (Icons.subtitles_rounded, 'Audio & subtitles', onAudioSubs);
      case 'quality':
        if (state.qualities.isEmpty && c.sourceQualities.length <= 1) {
          return null;
        }
        return (Icons.high_quality_rounded, 'Quality', onQuality);
      case 'sources':
        return (Icons.layers_rounded, 'Sources', onSources);
      case 'more':
        return (Icons.more_vert_rounded, 'More', () => _showMore(context));
      case 'episodes':
        if (onEpisodes == null) return null;
        return (Icons.video_library_outlined, 'Episodes', onEpisodes!);
      case 'fit':
        return (_fitIcon(zoomLabel), 'Aspect ratio · $zoomLabel', onZoom);
      case 'decoder':
        return (Icons.memory_rounded, 'Decoder · $decoderLabel', onDecoder);
      case 'enhance':
        return (
          enhanceActive
              ? Icons.auto_awesome_rounded
              : Icons.auto_awesome_outlined,
          'Anime4K enhancement',
          onEnhance,
        );
      case 'colour':
        return (Icons.palette_outlined, 'Colour', onColorProfile);
      case 'snapshot':
        return (Icons.photo_camera_rounded, 'Snapshot', onScreenshot);
      case 'sleep':
        return (
          sleepActive ? Icons.bedtime_rounded : Icons.bedtime_outlined,
          'Sleep timer',
          onSleep,
        );
      case 'pip':
        if (onPip == null) return null;
        return (
          Icons.picture_in_picture_alt_rounded,
          'Picture-in-picture',
          onPip!,
        );
    }
    return null; // unknown id — a layout from a newer build
  }

  /// Turns saved control ids into real buttons.
  ///
  /// The availability rules that were baked into the old fixed row still
  /// apply on top of the user's arrangement — Quality with nothing to pick
  /// between, Episodes on a single-episode item and PiP where the device
  /// doesn't support it drop out even if they've been placed on the bar.
  /// Anything unrecognised is skipped rather than crashing, which is what
  /// makes a layout saved by a newer build safe to load.
  List<Widget> _barButtons(BuildContext context, List<String> ids) {
    return [
      for (final id in ids)
        if (_specFor(context, id) case (final icon, final tip, final tap))
          _BarButton(icon: icon, tooltip: tip, onTap: tap),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ep = c.currentEpisode;
    final epNum = ep.number?.toInt() ?? state.currentIndex + 1;
    // The episode's own name, but only when it's more than a generic
    // "Episode N" / bare number (many sources just echo the number there).
    final epName = ep.title.trim();
    final hasEpName =
        epName.isNotEmpty &&
        epName.toLowerCase() != 'episode $epNum' &&
        epName != '$epNum';
    // Line 1 = show name (falls back to "Episode N" when no show title).
    final primaryTitle = showTitle ?? 'Episode $epNum';
    // Line 2 = "E5 · Episode Name" — only when there's a show name above it to
    // pair with (otherwise line 1 already carries the episode number).
    final secondaryTitle = showTitle == null
        ? null
        : 'E$epNum${hasEpName ? ' · $epName' : ''}';
    // Quality appended to the E-line (reDantotsu-style) when enabled — prefers
    // the source's quality label, else the live video height (e.g. "1080p").
    String? qualityLabel;
    if (showQuality) {
      final q = state.active?.quality?.trim();
      if (q != null && q.isNotEmpty && q.toLowerCase() != 'auto') {
        qualityLabel = q;
      } else {
        final h = c.player.state.height ?? 0;
        if (h > 0) qualityLabel = '${h}p';
      }
    }
    final secondaryLine = qualityLabel == null
        ? secondaryTitle
        : (secondaryTitle == null
              ? qualityLabel
              : '$secondaryTitle · $qualityLabel');
    final hasNext = state.currentIndex + 1 < c.episodes.length;
    // Movies and one-off items have nowhere to step, so they get a lone play
    // button rather than two arrows that can never do anything.
    final multiEpisode = c.episodes.length > 1;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Top scrim.
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 110,
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
        // Bottom scrim. There were two of these stacked at each end — 0xCC over
        // 0x99 up top, 0xE6 over 0xB3 down here — which is why showing the
        // controls dropped a heavy curtain over the video. One gentle pass each
        // way is plenty to keep white text legible on a bright frame.
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 170,
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

        // Top bar.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            // Vertical insets only. Now that the window draws into the display
            // cutout, the horizontal safe inset is the camera's — and it exists
            // on one edge only, so honouring it shunts the whole bar sideways
            // and the margins stop matching. The cutout sits mid-edge; this bar
            // is pinned to the top, so they never meet.
            left: false,
            right: false,
            child: Padding(
              // 32, not the bottom block's 44, and the difference is on
              // purpose: these are IconButtons, which reserve 12px around the
              // glyph before it draws (8 default padding, plus 4 stretching the
              // 40px button out to the 48px minimum touch target). 32 + 12 puts
              // the back arrow on 44 — the exact line the bottom capsules start
              // at. Writing 44 here would land it at 56 and overshoot inward.
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                    tooltip: 'Back',
                    onPressed: onBack,
                  ),
                  // Text hit-tests as opaque (RenderParagraph.hitTestSelf is
                  // true), so the title used to eat taps aimed at the video —
                  // a wide dead strip across the top where tapping did nothing.
                  // Nothing here is interactive, so let taps fall through to the
                  // zones below and toggle the controls like anywhere else.
                  Expanded(
                    child: IgnorePointer(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  primaryTitle,
                                  style: AppText.headline.copyWith(
                                    color: Colors.white,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              // Filler comes from the Jikan lookup, not the
                              // source — Episode.filler is always false here.
                              // Listened to because that lookup lands long
                              // after this is first built.
                              ValueListenableBuilder<Set<int>>(
                                valueListenable: c.fillerEpisodes,
                                builder: (context, _, _) =>
                                    c.isFillerAt(state.currentIndex)
                                    ? const Padding(
                                        padding: EdgeInsets.only(left: 8),
                                        // No colour passed: TagBadge falls back
                                        // to the app accent, so the badge
                                        // follows the user's theme colour.
                                        child: TagBadge(text: 'FILLER'),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                          if (secondaryLine != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 1),
                              child: Text(
                                secondaryLine,
                                style: AppText.caption.copyWith(
                                  color: Colors.white70,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // Whatever the user put up here, in their order. Cast and
                  // the ⓘ stats toggle live here by default; anything else in
                  // the registry can be moved up in Settings.
                  ..._topButtons(context, barConfig.top),
                  // Sleep timer armed — a visible accent moon; tap to adjust or
                  // cancel. Only shown while a timer / end-of-episode is set,
                  // and only when Sleep isn't already placed somewhere, or an
                  // armed timer would show two of the same button.
                  if (sleepActive && !_placedAnywhere('sleep'))
                    IconButton(
                      icon: Icon(Icons.bedtime_rounded,
                          color: AppColors.accent),
                      tooltip: 'Sleep timer on',
                      onPressed: onSleep,
                    ),
                  // Episodes and ⋮ More live in the bottom bar now — a second
                  // copy up here just split the same action across two places.
                  // Lock stays: it's the one control you want reachable without
                  // looking down at the bar you're about to hide.
                  IconButton(
                    icon: const Icon(
                      Icons.lock_open_rounded,
                      color: Colors.white,
                    ),
                    tooltip: 'Lock controls',
                    onPressed: onLock,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.settings_rounded,
                      color: Colors.white,
                    ),
                    tooltip: 'Settings',
                    onPressed: onSettings,
                  ),
                  if (onChat != null)
                    IconButton(
                      icon: const Icon(
                        Icons.chat_bubble_outline_rounded,
                        color: Colors.white,
                      ),
                      tooltip: 'Chat',
                      onPressed: onChat,
                    ),
                ],
              ),
            ),
          ),
        ),

        // Centre transport — episode step either side of play/pause. The ±10s
        // buttons used to live here, but they jumped a hardcoded 10s while
        // double-tap honoured the user's Double-tap skip setting, so the two
        // disagreed; seeking is covered by double-tap, drag-to-seek and the
        // MegaSkip pill, all of which read the same preference.
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (multiEpisode) ...[
                _TransportButton(
                  icon: Icons.skip_previous_rounded,
                  label: 'Previous episode',
                  onTap: onPrev,
                ),
                const SizedBox(width: 24),
              ],
              StreamBuilder<bool>(
                stream: c.player.stream.buffering,
                builder: (context, bSnap) {
                  final buffering = bSnap.data ?? c.player.state.buffering;
                  // While buffering, show the spinner IN PLACE OF the play/pause
                  // button — no more spinner-over-button overlap. 58px matches
                  // _AnimatedPlayPause's disc exactly, so the episode arrows
                  // don't twitch every time playback stalls.
                  if (buffering) {
                    return const SizedBox(
                      width: 58,
                      height: 58,
                      child: Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 3,
                          ),
                        ),
                      ),
                    );
                  }
                  return StreamBuilder<bool>(
                    stream: c.player.stream.playing,
                    builder: (context, snap) {
                      final playing = snap.data ?? c.player.state.playing;
                      return _AnimatedPlayPause(
                        playing: playing,
                        onTap: () {
                          c.togglePlay();
                          onInteract();
                        },
                      );
                    },
                  );
                },
              ),
              if (multiEpisode) ...[
                const SizedBox(width: 24),
                _TransportButton(
                  icon: Icons.skip_next_rounded,
                  label: 'Next episode',
                  onTap: hasNext
                      ? () {
                          c.playNext();
                          onInteract();
                        }
                      : null,
                ),
              ],
            ],
          ),
        ),

        // Bottom: seek row + buttons. Rises into place as it fades in — the
        // motion reads as instant even when the tap resolves a beat later.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: AnimatedSlide(
            offset: visible ? Offset.zero : const Offset(0, 0.14),
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            child: SafeArea(
            top: false,
            // Vertical inset only — the bottom one keeps the bar clear of the
            // gesture nav. See the top bar for why the horizontal cutout inset
            // is skipped: it lands on one edge only and pushed this whole block
            // sideways, leaving a fat gap on the camera side and a thin one
            // opposite. The camera sits mid-edge, well clear of this bar.
            left: false,
            right: false,
            child: Padding(
              // One margin for the whole block — timestamp, progress bar and
              // both button groups share it, so every edge lines up. Kept wide
              // so the controls sit clear of the screen edges.
              padding: const EdgeInsets.fromLTRB(44, 0, 44, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Duration tracker (off-screen listener via StreamBuilder).
                  StreamBuilder<Duration>(
                    stream: c.player.stream.duration,
                    builder: (context, snap) {
                      final d = snap.data ?? duration;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (d > Duration.zero) onDurationChanged(d);
                      });
                      return _SeekRow(
                        controller: c,
                        duration: d > Duration.zero ? d : duration,
                        onInteract: onInteract,
                        // MegaSkip — manual jump-forward, riding the timestamp's
                        // line rather than a row of its own above it.
                        trailing: megaSkipEnabled
                            ? _MegaSkipPill(
                                seconds: megaSkipSeconds,
                                onTap: onMegaSkip,
                              )
                            : null,
                      );
                    },
                  ),
                  const SizedBox(height: 2),
                  // Control bar under the progress bar: the pickers ride in one
                  // translucent group on the left, episode list + fit mode in
                  // another on the right. Two groups rather than seven floating
                  // chips — the split reads at a glance, and every button is the
                  // same width so nothing shifts as the video changes.
                  Builder(
                    builder: (context) {
                      // Rendered from the user's saved arrangement rather than
                      // a fixed row. Untouched prefs give the defaults, which
                      // are the exact layout that shipped before the Settings
                      // screen existed — so nobody's bar moves unless they
                      // move it.
                      final left = _barButtons(context, barConfig.left);
                      final right = _barButtons(context, barConfig.right);
                      return Row(
                        children: [
                          if (left.isNotEmpty) _BarGroup(children: left),
                          const Spacer(),
                          if (right.isNotEmpty) _BarGroup(children: right),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Seek row — current time + slider (stream-bound) + total time.
// ─────────────────────────────────────────────────────────────────────────────

