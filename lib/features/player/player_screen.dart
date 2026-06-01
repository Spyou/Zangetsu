import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/brand_loader.dart';
import '../../core/ui/frosted_surface.dart';
import 'player_controller.dart';

/// Netflix-style fullscreen player: a live [Video] with a tap-to-toggle
/// overlay (auto-hiding), double-tap ±10s seek, long-press 2x speed, a
/// stream-bound seek slider, and Speed / Audio / Quality / Source / Next
/// controls. Forces landscape + immersive UI while open and restores portrait
/// on dispose.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.sourceId,
    required this.episodes,
    required this.startIndex,
    required this.resume,
    required this.resolveSources,
    this.history,
    this.showTitle,
    this.cover,
    this.coverHeaders,
    this.showUrl,
    this.category,
  });

  final String sourceId;
  final List<Episode> episodes;
  final int startIndex;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;

  // Optional show-context threaded into history (Continue Watching feed).
  final WatchHistory? history;
  final String? showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String? showUrl;
  final String? category;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlayerController _c;

  bool _controlsVisible = true;
  bool _holding = false; // long-press 2x active
  Timer? _hideTimer;

  // Transient ±10 seek label.
  String? _seekLabel;
  Timer? _seekLabelTimer;

  // Duration tracked off the stream so the slider has a max even before
  // a position event arrives.
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _c = PlayerController(
      sourceId: widget.sourceId,
      episodes: widget.episodes,
      resume: widget.resume,
      resolveSources: widget.resolveSources,
      dio: sl<Dio>(),
      history: widget.history,
      showTitle: widget.showTitle,
      cover: widget.cover,
      coverHeaders: widget.coverHeaders,
      showUrl: widget.showUrl,
      category: widget.category,
    )..init(widget.startIndex);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _seekLabelTimer?.cancel();
    _c.dispose();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ── Controls visibility ─────────────────────────────────────────────────

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      // Don't hide while paused (no auto-hide when not playing).
      if (mounted && _c.player.state.playing) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  /// Keep controls up and reset the auto-hide timer after any interaction.
  void _bumpControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _showSeekLabel(String label) {
    _seekLabelTimer?.cancel();
    setState(() => _seekLabel = label);
    _seekLabelTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekLabel = null);
    });
  }

  // ── Gestures ────────────────────────────────────────────────────────────

  void _onDoubleTapDown(TapDownDetails d) {
    final w = MediaQuery.of(context).size.width;
    final x = d.localPosition.dx;
    if (x < w / 3) {
      _c.seekBy(const Duration(seconds: -10));
      _showSeekLabel('-10');
    } else if (x > w * 2 / 3) {
      _c.seekBy(const Duration(seconds: 10));
      _showSeekLabel('+10');
    } else {
      _c.togglePlay();
    }
    _bumpControls();
  }

  // ── Sheets ──────────────────────────────────────────────────────────────

  Future<T?> _sheet<T>(Widget child) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => FrostedSurface(
        blur: true,
        opacity: 0.75,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: SafeArea(top: false, child: child),
      ),
    );
  }

  void _openSpeedSheet() {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final current = _c.player.state.rate;
    _sheet<void>(
      _SheetColumn(
        header: 'Playback Speed',
        children: [
          for (final r in rates)
            _SheetRow(
              label: r == 1.0 ? 'Normal' : '${r}x',
              active: (current - r).abs() < 0.01,
              onTap: () {
                Navigator.pop(context);
                _c.setRate(r);
                _bumpControls();
              },
            ),
        ],
      ),
    );
  }

  void _openAudioSheet() {
    final kinds = _c.audioKinds;
    final active = _c.activeKind;
    _sheet<void>(
      _SheetColumn(
        header: 'Audio',
        children: [
          for (final k in kinds)
            _SheetRow(
              label: k.name.toUpperCase(),
              active: active == k,
              onTap: () {
                Navigator.pop(context);
                _c.switchAudio(k);
                _bumpControls();
              },
            ),
        ],
      ),
    );
  }

  void _openQualitySheet() {
    _sheet<void>(
      _SheetColumn(
        header: 'Quality',
        children: [
          _SheetRow(
            label: 'Auto',
            active: _c.activeQuality == null,
            onTap: () {
              Navigator.pop(context);
              _c.selectQuality(null);
              _bumpControls();
            },
          ),
          for (final v in _c.qualities)
            _SheetRow(
              label: v.quality,
              active: _c.activeQuality?.url == v.url,
              onTap: () {
                Navigator.pop(context);
                _c.selectQuality(v);
                _bumpControls();
              },
            ),
        ],
      ),
    );
  }

  void _openSourceSheet() {
    final kinds = availableKinds(_c.sources);
    _sheet<void>(
      _SheetColumn(
        header: 'Sources',
        children: [
          for (final k in kinds)
            for (final s in sortByQuality(sourcesForKind(_c.sources, k)))
              _SheetRow(
                label: '${k.name.toUpperCase()} • '
                    '${s.quality?.isNotEmpty == true ? s.quality : s.container.name}',
                active: s == _c.active,
                onTap: () {
                  Navigator.pop(context);
                  _c.switchSource(s);
                  _bumpControls();
                },
              ),
        ],
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          if (_c.loadingSources) {
            return const Center(
              child: BrandLoader(label: 'Finding the best source…'),
            );
          }
          if (_c.error != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline,
                        size: 40, color: AppColors.textTertiary),
                    const SizedBox(height: 12),
                    Text(_c.error!,
                        style: AppText.body, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => _c.openEpisode(_c.currentIndex),
                      child: Text('Try again',
                          style: AppText.body
                              .copyWith(color: AppColors.accent)),
                    ),
                  ],
                ),
              ),
            );
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              // 1. The video.
              Center(child: Video(controller: _c.videoController)),

              // 2. Gesture surface: tap toggles, double-tap seeks, long-press 2x.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  onDoubleTapDown: _onDoubleTapDown,
                  onDoubleTap: () {}, // arm double-tap recognizer
                  onLongPressStart: (_) {
                    _c.setRate(2.0);
                    setState(() => _holding = true);
                  },
                  onLongPressEnd: (_) {
                    _c.setRate(1.0);
                    setState(() => _holding = false);
                  },
                ),
              ),

              // 3. Buffering spinner when controls are hidden.
              StreamBuilder<bool>(
                stream: _c.player.stream.buffering,
                builder: (context, snap) {
                  final buffering = snap.data ?? false;
                  if (!buffering || _controlsVisible) {
                    return const SizedBox.shrink();
                  }
                  return const Center(
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: CircularProgressIndicator(
                          color: AppColors.accent, strokeWidth: 2.5),
                    ),
                  );
                },
              ),

              // 4. ±10 seek label.
              if (_seekLabel != null)
                Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                      child: Text(
                        '$_seekLabel s',
                        style: AppText.headline
                            .copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ),

              // 5. 2x-hold chip (top-center).
              if (_holding)
                Positioned(
                  top: 12,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        child: Text(
                          '2x ▶▶',
                          style: AppText.caption.copyWith(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // 6. Controls overlay.
              AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: _ControlsOverlay(
                    controller: _c,
                    showTitle: widget.showTitle,
                    duration: _duration,
                    onDurationChanged: (d) {
                      if (mounted && d != _duration) {
                        setState(() => _duration = d);
                      }
                    },
                    onInteract: _bumpControls,
                    onBack: () => Navigator.of(context).maybePop(),
                    onSpeed: _openSpeedSheet,
                    onAudio: _openAudioSheet,
                    onQuality: _openQualitySheet,
                    onSources: _openSourceSheet,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Controls overlay — top bar, center transport, bottom seek + button row.
// ─────────────────────────────────────────────────────────────────────────────

class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.controller,
    required this.showTitle,
    required this.duration,
    required this.onDurationChanged,
    required this.onInteract,
    required this.onBack,
    required this.onSpeed,
    required this.onAudio,
    required this.onQuality,
    required this.onSources,
  });

  final PlayerController controller;
  final String? showTitle;
  final Duration duration;
  final ValueChanged<Duration> onDurationChanged;
  final VoidCallback onInteract;
  final VoidCallback onBack;
  final VoidCallback onSpeed;
  final VoidCallback onAudio;
  final VoidCallback onQuality;
  final VoidCallback onSources;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final epNum = c.currentEpisode.number?.toInt() ?? c.currentIndex + 1;
    final title =
        'Episode $epNum${showTitle != null ? " · $showTitle" : ""}';
    final hasNext = c.currentIndex + 1 < c.episodes.length;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Top scrim.
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 120,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xCC000000), Color(0x00000000)],
              ),
            ),
          ),
        ),
        // Bottom scrim.
        const Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 200,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xE6000000), Color(0x00000000)],
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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: onBack,
                  ),
                  Expanded(
                    child: Text(
                      title,
                      style: AppText.headline.copyWith(color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Center transport.
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                iconSize: 40,
                icon: const Icon(Icons.replay_10, color: Colors.white),
                onPressed: () {
                  c.seekBy(const Duration(seconds: -10));
                  onInteract();
                },
              ),
              const SizedBox(width: 24),
              StreamBuilder<bool>(
                stream: c.player.stream.playing,
                builder: (context, snap) {
                  final playing = snap.data ?? c.player.state.playing;
                  return IconButton(
                    iconSize: 56,
                    icon: Icon(
                      playing
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_filled,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      c.togglePlay();
                      onInteract();
                    },
                  );
                },
              ),
              const SizedBox(width: 24),
              IconButton(
                iconSize: 40,
                icon: const Icon(Icons.forward_10, color: Colors.white),
                onPressed: () {
                  c.seekBy(const Duration(seconds: 10));
                  onInteract();
                },
              ),
            ],
          ),
        ),

        // Bottom: seek row + button row.
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
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
                      );
                    },
                  ),
                  const SizedBox(height: 2),
                  // Button row.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _ControlButton(
                        icon: Icons.speed,
                        label: 'Speed',
                        onTap: onSpeed,
                      ),
                      if (c.audioKinds.length > 1)
                        _ControlButton(
                          icon: Icons.graphic_eq,
                          label: 'Audio',
                          onTap: onAudio,
                        ),
                      if (c.qualities.isNotEmpty)
                        _ControlButton(
                          icon: Icons.high_quality,
                          label: 'Quality',
                          onTap: onQuality,
                        ),
                      _ControlButton(
                        icon: Icons.video_settings,
                        label: 'Sources',
                        onTap: onSources,
                      ),
                      if (hasNext)
                        _ControlButton(
                          icon: Icons.skip_next,
                          label: 'Next',
                          onTap: () {
                            c.playNext();
                            onInteract();
                          },
                        ),
                    ],
                  ),
                ],
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

class _SeekRow extends StatelessWidget {
  const _SeekRow({
    required this.controller,
    required this.duration,
    required this.onInteract,
  });

  final PlayerController controller;
  final Duration duration;
  final VoidCallback onInteract;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    return StreamBuilder<Duration>(
      stream: controller.player.stream.position,
      builder: (context, snap) {
        final pos = snap.data ?? Duration.zero;
        final posMs =
            pos.inMilliseconds.clamp(0, totalMs > 0 ? totalMs : 1).toDouble();
        return Row(
          children: [
            Text(_fmt(pos),
                style: AppText.caption.copyWith(color: Colors.white)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: AppColors.accent,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayColor: AppColors.accentSoft,
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 14),
                ),
                child: Slider(
                  min: 0,
                  max: totalMs > 0 ? totalMs.toDouble() : 1,
                  value: posMs,
                  onChanged: (_) => onInteract(),
                  onChangeEnd: (v) {
                    controller.seekTo(Duration(milliseconds: v.round()));
                    onInteract();
                  },
                ),
              ),
            ),
            Text(_fmt(duration),
                style: AppText.caption.copyWith(color: Colors.white)),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small bits.
// ─────────────────────────────────────────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(height: 3),
            Text(label,
                style: AppText.caption.copyWith(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

class _SheetColumn extends StatelessWidget {
  const _SheetColumn({required this.header, required this.children});
  final String header;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(2),
              ),
              child: const SizedBox(width: 36, height: 4),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Text(header, style: AppText.headline),
        ),
        Flexible(
          child: ListView(shrinkWrap: true, children: children),
        ),
      ],
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: active
          ? const Icon(Icons.check, color: AppColors.accent, size: 20)
          : const SizedBox(width: 20),
      title: Text(label,
          style: AppText.body.copyWith(color: AppColors.textPrimary)),
      onTap: onTap,
    );
  }
}
