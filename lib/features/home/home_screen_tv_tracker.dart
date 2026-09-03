// The tracker-driven rails of the TV home — same chrome as the local rails
// (landscape progress cards, poster rails), fed from the tracker library the
// cubit sliced into rows. TV has no editor; it mirrors the arrangement saved
// on the phone.
part of 'home_screen_tv.dart';

/// Tracker continue / new-episodes rail: the same landscape progress cards as
/// the local Continue Watching rail, one per in-progress entry. [newEpisodes]
/// switches the sub line from "where you are" to "what's waiting".
class _TvTrackerRail extends StatelessWidget {
  const _TvTrackerRail({
    required this.title,
    required this.items,
    required this.newEpisodes,
    required this.onOpen,
    this.firstAutofocus = false,
  });

  final String title;
  final List<TrackerListItem> items;
  final bool newEpisodes;
  final void Function(TrackerListItem) onOpen;
  final bool firstAutofocus;

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
              title,
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: _cardHeight + 60,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              padding: const EdgeInsets.symmetric(horizontal: 40),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final e = items[index];
                return Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: SizedBox(
                    width: _cardWidth,
                    child: _TvLandscapeCard(
                      title: e.item.title,
                      sub: newEpisodes
                          ? trackerNextSubtitle(e)
                          : trackerProgressSubtitle(e),
                      cover: e.item.cover,
                      headers: e.item.coverHeaders,
                      progress: trackerResumeFraction(e),
                      width: _cardWidth,
                      autofocus: firstAutofocus && index == 0,
                      onTap: () => onOpen(e),
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

/// A tracker status bucket rendered as the same poster rail a provider
/// section uses — [TvRail] over the entries' stubs.
class _TvTrackerListRail extends StatelessWidget {
  const _TvTrackerListRail({
    required this.row,
    required this.onOpen,
    this.firstAutofocus = false,
  });

  final TrackerListHomeRow row;
  final ValueChanged<MediaItem> onOpen;
  final bool firstAutofocus;

  @override
  Widget build(BuildContext context) {
    return TvRail(
      section: HomeSection(
        title: trackerStatusLabel(
          context,
          row.status,
          reading: trackerEntryIsReading(row.items.first),
        ),
        items: [for (final e in row.items) e.item],
      ),
      onTap: onOpen,
      firstAutofocus: firstAutofocus,
    );
  }
}
