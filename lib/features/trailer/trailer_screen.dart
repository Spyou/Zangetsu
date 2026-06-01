import 'package:flutter/material.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../core/theme/app_colors.dart';

/// In-app YouTube trailer playback. Embeds the video via
/// `youtube_player_iframe` (a WebView-backed iframe), autoplays it, and offers
/// a close affordance. The trailer id is resolved upstream by
/// `TrailerService` (AniList for anime, TMDB for movies/TV).
class TrailerScreen extends StatefulWidget {
  const TrailerScreen({super.key, required this.videoId});
  final String videoId;

  @override
  State<TrailerScreen> createState() => _TrailerScreenState();
}

class _TrailerScreenState extends State<TrailerScreen> {
  late final YoutubePlayerController _controller =
      YoutubePlayerController.fromVideoId(
    videoId: widget.videoId,
    autoPlay: true,
    params: const YoutubePlayerParams(
      showControls: true,
      showFullscreenButton: true,
      // youtube-nocookie.com — no tracking cookies for a one-off trailer.
      privacyEnhancedMode: true,
    ),
  );

  @override
  void dispose() {
    _controller.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // YoutubePlayer (v6) handles fullscreen internally via OverlayPortal — no
    // scaffold wrapper or SystemChrome calls needed; it's landscape-friendly
    // out of the box.
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Trailer centered on a black backdrop.
            Center(
              child: YoutubePlayer(
                controller: _controller,
                aspectRatio: 16 / 9,
              ),
            ),
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
}
