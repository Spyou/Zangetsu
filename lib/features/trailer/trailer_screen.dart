import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/trailer/trailer_service.dart';
import '../../core/ui/brand_loader.dart';

import '../../l10n/l10n.dart';

/// Fullscreen in-app trailer playback. Extracts a direct muxed stream for the
/// YouTube id (via [TrailerService.streamUrl]) and plays it natively with
/// media_kit — NO iframe, NO YouTube chrome (related videos / endscreen /
/// branding). Unmuted, with standard scrub/play-pause controls and a close
/// button. The id is resolved upstream by [TrailerService] (AniList for anime,
/// TMDB for movies/TV).
class TrailerScreen extends StatefulWidget {
  const TrailerScreen({super.key, required this.videoId});
  final String videoId;

  @override
  State<TrailerScreen> createState() => _TrailerScreenState();
}

class _TrailerScreenState extends State<TrailerScreen> {
  final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  // null = resolving; true = a stream is open; false = extraction failed.
  bool? _resolved;

  @override
  void initState() {
    super.initState();
    _resolveAndOpen();
  }

  Future<void> _resolveAndOpen() async {
    final svc = sl<TrailerService>();
    // HD path (opt-in): 1080p video + a separate audio stream attached as an
    // external track. Falls through to the light muxed stream if HD extraction
    // or playback setup fails, so the trailer still plays.
    if (sl<PlaybackPrefs>().trailerHd) {
      final hd = await svc.streamUrlHd(widget.videoId);
      if (!mounted) return;
      if (hd != null && await _openHd(hd)) return;
    }
    final url = await svc.streamUrl(widget.videoId, low: false);
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      setState(() => _resolved = false);
      return;
    }
    try {
      await _player.open(Media(url)); // unmuted, autoplay (default volume 100)
      if (!mounted) return;
      setState(() => _resolved = true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _resolved = false);
    }
  }

  /// Opens a HD video stream and attaches its separate audio stream. Returns
  /// true on success; false lets the caller fall back to the muxed stream.
  ///
  /// 1080p comes only as adaptive streams, which YouTube throttles — sometimes
  /// to a dead stall. So we require *real* playback (the position advancing)
  /// within a deadline; if it doesn't start, we bail to the reliable 360p muxed
  /// stream rather than freeze on a spinner forever.
  Future<bool> _openHd(({String video, String audio}) hd) async {
    try {
      Future<void> setup() async {
        await _player.open(Media(hd.video)); // unmuted, autoplay
        final p = _player.platform;
        if (p is NativePlayer) {
          // mpv: load the audio-only stream as an external track and select it.
          try {
            await p.command(['audio-add', hd.audio, 'select']);
          } catch (_) {/* audio failing shouldn't sink the HD attempt */}
        }
        // Throttled 1080p stalls here — position never leaves zero.
        await _player.stream.position.firstWhere((pos) => pos > Duration.zero);
      }

      await setup().timeout(const Duration(seconds: 8));
      if (!mounted) return true;
      setState(() => _resolved = true);
      return true;
    } catch (_) {
      return false; // stalled/failed → caller falls back to 360p muxed
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Center(child: _content()),
            // Close button over the top-left.
            Positioned(
              top: 4,
              left: 4,
              child: Material(
                color: Colors.black.withValues(alpha: 0.45),
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: AppColors.textPrimary,
                  ),
                  tooltip: context.l10n.close,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    switch (_resolved) {
      case null:
        return BrandLoader(label: context.l10n.loadingTrailer);
      case false:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.movie_filter_outlined,
              color: AppColors.textSecondary,
              size: 40,
            ),
            const SizedBox(height: 12),
            Text(context.l10n.trailerUnavailable, style: AppText.body),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(context.l10n.close),
            ),
          ],
        );
      case true:
        // Standard adaptive controls (scrub / play-pause) over a 16:9 stage;
        // landscape-friendly. NO YouTube chrome.
        return AspectRatio(
          aspectRatio: 16 / 9,
          child: Video(
            controller: _controller,
            controls: AdaptiveVideoControls,
            fit: BoxFit.contain,
          ),
        );
    }
  }
}
