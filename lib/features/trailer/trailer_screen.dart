import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/trailer/trailer_service.dart';
import '../../core/ui/brand_loader.dart';

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
    final url =
        await sl<TrailerService>().streamUrl(widget.videoId, low: false);
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
                  icon: const Icon(Icons.close_rounded,
                      color: AppColors.textPrimary),
                  tooltip: 'Close',
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
        return const BrandLoader(label: 'Loading trailer…');
      case false:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.movie_filter_outlined,
                color: AppColors.textSecondary, size: 40),
            const SizedBox(height: 12),
            Text('Trailer unavailable', style: AppText.body),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Close'),
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
