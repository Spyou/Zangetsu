import 'dart:async';
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

  /// Info scroll drives the ambient glow: full at the top, plain black once
  /// the list moves. A notifier (not setState) so scrolling never rebuilds
  /// the page — only the glow repaints.
  late final ScrollController _scroll;
  final ValueNotifier<double> _ambient = ValueNotifier(1.0);

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController()..addListener(_fadeAmbient);
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
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _playingSub?.cancel();
    _scroll.dispose();
    _ambient.dispose();
    super.dispose();
  }

  void _fadeAmbient() {
    if (!_scroll.hasClients) return;
    _ambient.value = (1 - _scroll.offset / 120).clamp(0.0, 1.0);
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
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // The glow bleeds past the card; Clip.none lets it show. It is
            // purely decorative — taps fall through to the page.
            Stack(
              clipBehavior: Clip.none,
              children: [_ambientGlow(), _video(videoH)],
            ),
            Expanded(child: _info()),
          ],
        ),
      ),
    );
  }

  // ── Video ────────────────────────────────────────────────────────────────

  /// YouTube-style ambient glow: the cover art blurred wide behind the mini
  /// player so its colours bleed onto the page. Fades to plain black as the
  /// info scrolls — the glow belongs to the video, not the list.
  Widget _ambientGlow() {
    final cover = (widget.coverUrl ?? '').trim();
    if (cover.isEmpty) return const SizedBox.shrink();
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<double>(
          valueListenable: _ambient,
          builder: (context, t, _) => Opacity(
            opacity: t * 0.75,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 36, sigmaY: 36),
              child: Transform.scale(
                scale: 1.25,
                child: CachedNetworkImage(
                  imageUrl: cover,
                  httpHeaders: widget.coverHeaders,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
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
    final pad = MediaQuery.paddingOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(12, pad.top + 4, 12, 0),
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
                    onPressed: widget.hasPrevious ? widget.onPrevious : null,
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
                    onPressed: widget.nextTitle != null ? widget.onNext : null,
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
                final value = pos.inMilliseconds
                    .toDouble()
                    .clamp(0.0, maxMs);
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
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
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
          _upNextHeader(l10n),
          if (widget.nextTitle != null) ...[
            const SizedBox(height: 8),
            _upNextCard(),
          ],
          const SizedBox(height: 16),
          _episodeList(l10n),
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
          _chip(
            Icons.subtitles_outlined,
            l10n.subtitles,
            widget.onSubtitles,
          ),
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
              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _upNextHeader(AppLocalizations l10n) {
    return Row(
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
          l10n.watchUpNext,
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
    );
  }

  Widget _upNextCard() {
    final thumb = (widget.nextThumb ?? '').trim();
    return GestureDetector(
      onTap: widget.onNext,
      child: FrostedSurface(
        blur: false,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (thumb.isNotEmpty)
                Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 118,
                        height: 66,
                        child: CachedNetworkImage(
                          imageUrl: thumb,
                          httpHeaders: widget.coverHeaders,
                          fit: BoxFit.cover,
                          errorWidget: (_, _, _) =>
                              Container(color: Colors.white10),
                        ),
                      ),
                    ),
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ],
                ),
              if (thumb.isNotEmpty) const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.nextLabel != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          widget.nextLabel!,
                          style: AppText.caption.copyWith(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    if (widget.nextLabel != null) const SizedBox(height: 6),
                    Text(
                      widget.nextTitle!,
                      style: AppText.body.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The episode list, inline — the list IS the picker, so there is no
  /// All-episodes button. Tapping opens that index; the current row glows.
  Widget _episodeList(AppLocalizations l10n) {
    if (widget.episodes.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            '${l10n.watchEpisodes} (${widget.episodes.length})',
            style: AppText.caption.copyWith(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (final ep in widget.episodes) _episodeRow(ep),
      ],
    );
  }

  Widget _episodeRow(WatchPageEpisode ep) {
    final current = ep.current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: () => widget.onOpenEpisode(ep.index),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: current
                ? AppColors.accent.withValues(alpha: 0.16)
                : AppColors.surface2,
            borderRadius: BorderRadius.circular(16),
            border: current
                ? Border.all(color: AppColors.accent, width: 1)
                : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  ep.label,
                  style: AppText.body.copyWith(
                    color: current ? AppColors.accent : Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                current
                    ? Icons.play_arrow_rounded
                    : Icons.chevron_right_rounded,
                color: current ? AppColors.accent : AppColors.textSecondary,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
