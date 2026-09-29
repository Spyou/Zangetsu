// Continue Watching rail and the landscape progress card it (and the tracker
// rails) build from.
part of 'home_screen_tv.dart';

// ── Continue Watching Rail ──────────────────────────────────────────────────

/// A labelled row of D-pad-focusable Continue Watching cards (poster + progress
/// bar). OK resumes the episode at its saved position. Mirrors the phone home's
/// Continue Watching row; fed by the same login-gated [WatchHistory.recent].
class _TvContinueRail extends StatelessWidget {
  const _TvContinueRail({
    required this.history,
    required this.onResume,
    this.onLongPress,
    this.firstAutofocus = false,
  });

  final List<HistoryEntry> history;
  final void Function(HistoryEntry) onResume;
  final void Function(HistoryEntry)? onLongPress;
  final bool firstAutofocus;

  // Landscape (16:9) art reads better than the phone's portrait ContinueCard on
  // a TV row — it's what Netflix/Disney+ TV apps do too.
  static const double _cardWidth = 300;
  static const double _cardHeight = 176; // 16:9 of 300

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              context.l10n.continueWatching,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Landscape art + two lines of text below; snug headroom for the
          // focused card's scale-up (Clip.none lets it spill, so no crop).
          SizedBox(
            height: _cardHeight + 60,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(horizontal: 40),
              itemCount: history.length,
              itemBuilder: (context, index) {
                final e = history[index];
                final sub = e.episodeNumber != null
                    ? context.l10n.continueDotEpisode(e.episodeNumber!.toInt())
                    : context.l10n.continueLabel;
                return Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: SizedBox(
                    width: _cardWidth,
                    child: _TvLandscapeCard(
                      title: e.showTitle,
                      sub: sub,
                      cover: e.cover,
                      headers: e.coverHeaders,
                      progress: e.progress,
                      width: _cardWidth,
                      autofocus: firstAutofocus && index == 0,
                      onTap: () => onResume(e),
                      onLongPress: onLongPress == null
                          ? null
                          : () => onLongPress!(e),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// TV-only LANDSCAPE progress card (16:9 art + progress overlay, with the
/// title and a sub line below) — the data-agnostic card the local Continue
/// Watching rail AND the tracker rows build from. Landscape reads better on
/// TV than the shared portrait ContinueCard; that shared widget is left
/// untouched for the phone.
class _TvLandscapeCard extends StatelessWidget {
  const _TvLandscapeCard({
    required this.title,
    required this.sub,
    required this.progress,
    required this.width,
    required this.onTap,
    this.cover,
    this.headers,
    this.onLongPress,
    this.autofocus = false,
  });

  final String title;
  final String sub;

  /// Resume progress in [0, 1], drawn as the bar pinned to the art's base.
  final double progress;
  final double width;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool autofocus;
  final String? cover;
  final Map<String, String>? headers;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Only the 16:9 ART gets the float focus (white outline hugs it).
          TvFocusable(
            autofocus: autofocus,
            variant: TvFocusVariant.float,
            scale: 1.05,
            onTap: onTap,
            onLongPress: onLongPress,
            semanticLabel: '$title, $sub',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if ((cover ?? '').isNotEmpty)
                      CachedNetworkImage(
                        imageUrl: cover!,
                        cacheManager: AppImageCache.manager,
                        httpHeaders: headers,
                        fit: BoxFit.cover,
                        memCacheWidth: 600,
                        placeholder: (_, _) =>
                            ColoredBox(color: AppColors.surface2),
                        errorWidget: (_, _, _) =>
                            ColoredBox(color: AppColors.surface2),
                      )
                    else
                      ColoredBox(color: AppColors.surface2),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        height: 5,
                        color: Colors.black.withValues(alpha: 0.55),
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: progress.clamp(0.0, 1.0),
                          child: Container(color: AppColors.accent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Both excluded — the focusable above already announces title + sub
          // together via semanticLabel.
          ExcludeSemantics(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 2),
          ExcludeSemantics(
            child: Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
