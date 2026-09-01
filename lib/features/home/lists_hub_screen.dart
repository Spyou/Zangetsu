import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../l10n/l10n.dart';
import '../schedule/schedule_screen.dart';
import 'my_list_screen.dart';

/// Schedule and your tracker libraries, behind one door.
///
/// These used to be a card each on Home, which meant a strip of near-identical
/// slabs that grew every time a tracker was added and had to be filtered per
/// mode to stay a sensible width. A screen has room to say what each
/// destination actually is, and it drops the per-mode juggling entirely: every
/// connected tracker gets a row per kind of list it holds, named on the row, so
/// nothing here depends on the mode you arrived in.
class ListsHubScreen extends StatelessWidget {
  const ListsHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final trackers = sl.isRegistered<TrackerHub>()
        ? sl<TrackerHub>().connected.toList()
        : const <Tracker>[];
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text(context.l10n.scheduleAndLists, style: AppText.barTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          const _SectionLabel('BROWSE'),
          const SizedBox(height: 12),
          _HubRow(
            icon: Icons.calendar_month_rounded,
            tint: AppColors.accent,
            title: context.l10n.schedule,
            desc: context.l10n.scheduleHubDesc,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ScheduleScreen()),
            ),
          ),
          for (final t in trackers) ...[
            const SizedBox(height: 28),
            _SectionLabel(t.displayName.toUpperCase()),
            const SizedBox(height: 12),
            for (final k in _kindsFor(t)) ...[
              _HubRow(
                icon: _iconFor(k),
                tint: _tintFor(t),
                title: _titleFor(context, t, k),
                desc: _descFor(context, k),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        MyListScreen(initialTracker: t, initialKind: k),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ],
      ),
    );
  }

  /// Which lists a tracker actually holds. AniList and MAL split light novels
  /// out of the manga list (by `format`/`media_type`), so a novel row there has
  /// real content rather than being a permanently empty tab. Simkl has no
  /// reading side at all, so it gets the one row.
  static List<ContentMode> _kindsFor(Tracker t) => t.supportsReading
      ? const [ContentMode.anime, ContentMode.manga, ContentMode.novel]
      : const [ContentMode.anime];

  static IconData _iconFor(ContentMode k) => switch (k) {
    ContentMode.anime => Icons.play_circle_outline_rounded,
    ContentMode.manga => Icons.auto_stories_outlined,
    ContentMode.novel => Icons.menu_book_outlined,
  };

  /// A video-only tracker's single row says what it covers; elsewhere the kind
  /// is the whole point of the row, so it is the title.
  static String _titleFor(BuildContext context, Tracker t, ContentMode k) =>
      t.supportsReading
      ? _kindLabel(context, k)
      : context.l10n.trackerCoversVideo;

  static String _kindLabel(BuildContext context, ContentMode k) => switch (k) {
    ContentMode.anime => context.l10n.anime,
    ContentMode.manga => context.l10n.listKindManga,
    ContentMode.novel => context.l10n.listKindNovel,
  };

  static String _descFor(BuildContext context, ContentMode k) => switch (k) {
    ContentMode.anime => context.l10n.listKindAnimeDesc,
    ContentMode.manga => context.l10n.listKindMangaDesc,
    ContentMode.novel => context.l10n.listKindNovelDesc,
  };

  /// Each service's own colour, so the rows are told apart by more than their
  /// wording. Falls back to the app accent for anything unrecognised, which is
  /// what a newly added tracker gets until it is given one.
  static Color _tintFor(Tracker t) => switch (t.displayName) {
    'AniList' => const Color(0xFF02A9FF),
    'MyAnimeList' => const Color(0xFF2E51A2),
    'Simkl' => const Color(0xFF00B4E4),
    _ => AppColors.accent,
  };
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: Text(text, style: AppText.overline),
  );
}

/// Same furniture as the Sources hub's row, so drilling into either reads the
/// same way.
class _HubRow extends StatelessWidget {
  const _HubRow({
    required this.icon,
    required this.tint,
    required this.title,
    required this.desc,
    required this.onTap,
  });

  final IconData icon;
  final Color tint;
  final String title;
  final String desc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: tint, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: AppText.headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(desc, style: AppText.caption),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}
