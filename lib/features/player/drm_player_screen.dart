import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/models/video_source.dart';
import '../../core/theme/app_colors.dart';
import 'tv_exo_controller.dart';

/// A dedicated fullscreen player for DRM (clearkey CENC/DASH) sources — the
/// CNC/PlayzTV live channels mpv can't decrypt. It renders the native ExoPlayer
/// PlatformView (see ExoPlayerView.kt, which builds the clearkey session) behind
/// a touch control overlay styled to match the main player.
///
/// Kept deliberately separate from the mpv [player_screen] and the D-pad
/// [TvPlayerActivity] so NEITHER of those is touched: DRM playback lives entirely
/// here. The main player hands off to this screen when it picks a DRM source.
class DrmPlayerScreen extends StatefulWidget {
  const DrmPlayerScreen({
    super.key,
    required this.sources,
    required this.initial,
    this.title,
    this.subtitle,
  });

  /// Every resolved source for the episode (so the user can switch mirror). The
  /// DRM one plays first; non-DRM mirrors are offered too (they just carry no key).
  final List<VideoSource> sources;

  /// The source to play first — the DRM mirror the main player picked.
  final VideoSource initial;

  final String? title;
  final String? subtitle;

  @override
  State<DrmPlayerScreen> createState() => _DrmPlayerScreenState();
}

class _DrmPlayerScreenState extends State<DrmPlayerScreen> {
  TvExoController? _c;
  late VideoSource _current = widget.initial;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _current = widget.initial;
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _c?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _onViewCreated(int id) {
    final c = TvExoController(id);
    _c = c;
    c.buffering.addListener(_rebuild);
    c.playing.addListener(_rebuild);
    c.position.addListener(_rebuild);
    c.duration.addListener(_rebuild);
    _play(_current);
    _bumpControls();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _play(VideoSource s) async {
    _current = s;
    await _c?.setSource(
      s.url,
      s.headers ?? const {},
      mimeType: _mimeFor(s),
      drmKid: s.drmKid,
      drmKey: s.drmKey,
    );
  }

  /// Explicit container MIME so ExoPlayer builds the right MediaSource for a
  /// tokenized URL: DASH for `.mpd` (the DRM channels), HLS for `.m3u8`.
  static String? _mimeFor(VideoSource s) {
    final u = s.url.toLowerCase();
    if (u.contains('.mpd')) return 'application/dash+xml';
    if (s.container == SourceContainer.hls || u.contains('.m3u8')) {
      return 'application/x-mpegURL';
    }
    return null;
  }

  void _bumpControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_c?.playing.value ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _bumpControls();
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    c.playing.value ? c.pause() : c.play();
    _bumpControls();
  }

  String _fmt(int ms) {
    if (ms <= 0) return '0:00';
    final s = ms ~/ 1000;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  void _openSources() {
    _hideTimer?.cancel();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF15151A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('Sources',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in widget.sources)
                    ListTile(
                      leading: Icon(
                        s.isDrm ? Icons.lock_rounded : Icons.play_arrow_rounded,
                        color: s.url == _current.url
                            ? AppColors.accent
                            : Colors.white70,
                      ),
                      title: Text(
                        s.label ?? s.quality ?? 'Source',
                        style: TextStyle(
                          color: s.url == _current.url
                              ? AppColors.accent
                              : Colors.white,
                        ),
                      ),
                      subtitle: s.isDrm
                          ? const Text('DRM',
                              style: TextStyle(color: Colors.white38, fontSize: 12))
                          : null,
                      trailing: s.url == _current.url
                          ? Icon(Icons.check_rounded, color: AppColors.accent)
                          : null,
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _play(s);
                        _bumpControls();
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ).whenComplete(_bumpControls);
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final buffering = c?.buffering.value ?? true;
    final playing = c?.playing.value ?? false;
    final pos = c?.position.value ?? 0;
    final dur = c?.duration.value ?? 0;
    final isLive = dur <= 0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          children: [
            Positioned.fill(
              child: PlatformViewLink(
                viewType: 'zangetsu/exoplayer_view',
                surfaceFactory: (context, controller) => AndroidViewSurface(
                  controller: controller as AndroidViewController,
                  gestureRecognizers:
                      const <Factory<OneSequenceGestureRecognizer>>{},
                  hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                ),
                onCreatePlatformView: (params) {
                  return PlatformViewsService.initExpensiveAndroidView(
                    id: params.id,
                    viewType: 'zangetsu/exoplayer_view',
                    layoutDirection: TextDirection.ltr,
                    creationParams: const <String, dynamic>{},
                    creationParamsCodec: const StandardMessageCodec(),
                    onFocus: () => params.onFocusChanged(true),
                  )
                    ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
                    ..addOnPlatformViewCreatedListener(_onViewCreated)
                    ..create();
                },
              ),
            ),

            // Buffering spinner (until the first frame decodes).
            if (buffering && !playing)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),

            // Control overlay.
            AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xB3000000),
                        Color(0x00000000),
                        Color(0x00000000),
                        Color(0xCC000000),
                      ],
                      stops: [0, 0.25, 0.6, 1],
                    ),
                  ),
                  child: SafeArea(
                    child: Stack(
                      children: [
                        // Top: back + title.
                        Positioned(
                          top: 8,
                          left: 4,
                          right: 12,
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_back_rounded,
                                    color: Colors.white),
                                onPressed: () => Navigator.of(context).maybePop(),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.title ?? 'Live',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    if (widget.subtitle != null)
                                      Text(
                                        widget.subtitle!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: Colors.white60, fontSize: 13),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Center play/pause.
                        Center(
                          child: IconButton(
                            iconSize: 64,
                            icon: Icon(
                              playing
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_fill_rounded,
                              color: Colors.white,
                            ),
                            onPressed: _togglePlay,
                          ),
                        ),

                        // Bottom: progress (or LIVE) + Sources.
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 10,
                          child: Row(
                            children: [
                              if (isLive)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.accent,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('LIVE',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold)),
                                )
                              else ...[
                                Text(_fmt(pos),
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 12)),
                                Expanded(
                                  child: Slider(
                                    value: dur == 0
                                        ? 0
                                        : (pos / dur).clamp(0, 1).toDouble(),
                                    onChanged: (v) {
                                      _c?.seek((v * dur).round());
                                      _bumpControls();
                                    },
                                    activeColor: AppColors.accent,
                                    inactiveColor: Colors.white24,
                                  ),
                                ),
                                Text(_fmt(dur),
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 12)),
                              ],
                              const Spacer(),
                              TextButton.icon(
                                onPressed: _openSources,
                                icon: const Icon(Icons.playlist_play_rounded,
                                    color: Colors.white, size: 20),
                                label: const Text('Sources',
                                    style: TextStyle(color: Colors.white)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
