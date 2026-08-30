// The TV poster rail — one labelled row of D-pad cards.
part of 'home_screen_tv.dart';


// ── Poster Rail ───────────────────────────────────────────────────────────────

/// One labelled horizontal row of D-pad-focusable poster cards for a [HomeSection].
/// Public (not `_TvRail`) + [visibleForTesting] so tests can pump it directly.
@visibleForTesting
class TvRail extends StatelessWidget {
  const TvRail({
    super.key,
    required this.section,
    required this.onTap,
    this.onLongPress,
    this.onSeeAll,
    this.firstAutofocus = false,
  });

  final HomeSection section;
  final ValueChanged<MediaItem> onTap;

  /// Held OK on a poster — mirrors phone row long-press (info / My List sheet).
  /// Null keeps the snappy KeyDown tap (see [TvFocusable.onLongPress]).
  final ValueChanged<MediaItem>? onLongPress;
  final VoidCallback? onSeeAll;
  final bool firstAutofocus;

  static const double _cardWidth = 150;
  static const double _cardHeight = 225; // 2:3 poster

  @override
  Widget build(BuildContext context) {
    final items = section.items;
    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              section.title,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Card row. Height = poster + title + a little headroom for the
          // focused card's scale-up (the ListView is Clip.none so the growth and
          // its shadow spill past this box rather than being cropped). Kept snug
          // so rows don't float apart — the old +80 left a big dead band under
          // each title.
          SizedBox(
            height: _cardHeight + 44,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              // Don't clip the focused card's scale-up + accent glow. Combined
              // with the extra row headroom above, the top rail (pinned under
              // the hero) no longer crops the focused poster/title.
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(horizontal: 40),
              // +1 trailing "See all" card (D-pad: navigate right past the last
              // poster to reach it). Only when a handler is supplied.
              itemCount: items.length + (onSeeAll != null ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= items.length) {
                  // Trailing "See all" card — opens the full paginated grid.
                  return Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Center(
                      child: SizedBox(
                        width: _cardWidth,
                        height: _cardHeight,
                        child: TvFocusable(
                          onTap: onSeeAll!,
                          variant: TvFocusVariant.float,
                          scale: 1.10,
                          semanticLabel: context.l10n.seeAll,
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppColors.surface2,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.arrow_forward_rounded,
                                  color: AppColors.textPrimary,
                                  size: 28,
                                ),
                                const SizedBox(height: 8),
                                // Excluded — the focusable above already
                                // announces 'See all' via semanticLabel.
                                ExcludeSemantics(
                                  child: Text(
                                    context.l10n.seeAll,
                                    style: TextStyle(
                                      color: AppColors.textPrimary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }
                final item = items[index];
                // Only the poster ART gets the float focus (white outline hugs
                // the artwork); the title sits below, outside the outline.
                return Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: SizedBox(
                    width: _cardWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TvFocusable(
                          autofocus: firstAutofocus && index == 0,
                          variant: TvFocusVariant.float,
                          scale: 1.06,
                          onTap: () => onTap(item),
                          // Touch gestures stay on PosterCard null — TvFocusable
                          // owns OK (and held-OK when [onLongPress] is set).
                          onLongPress: onLongPress == null
                              ? null
                              : () => onLongPress!(item),
                          semanticLabel: item.title,
                          child: SizedBox(
                            width: _cardWidth,
                            height: _cardHeight,
                            child: PosterCard(
                              title: item.title,
                              imageUrl: item.cover,
                              headers: item.coverHeaders,
                              cellWidth: _cardWidth,
                              showTitle: false,
                              onTap: null,
                              onLongPress: null,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // The focusable above already announces the title —
                        // exclude this sibling so TalkBack doesn't say it twice.
                        ExcludeSemantics(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textSecondary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
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
