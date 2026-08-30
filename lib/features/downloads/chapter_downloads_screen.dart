import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../core/di/injector.dart';
import '../../core/download/chapter_download.dart';
import '../../core/download/chapter_download_store.dart';
import '../../core/download/chapter_downloader.dart';
import '../../core/models/episode.dart';
import '../../core/mode/content_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/states.dart';
import '../../l10n/l10n.dart';
import '../reader/manga_reader_screen.dart';
import '../reader/novel_reader_screen.dart';

/// Saved chapters for one reading mode.
///
/// One screen per mode rather than a shared list: manga is pages and novels
/// are text, they're browsed in different places, and mixing them under the
/// episode downloads made the video screen read like a dumping ground.
class ChapterDownloadsScreen extends StatefulWidget {
  const ChapterDownloadsScreen({super.key, required this.mode});

  final ContentMode mode;

  @override
  State<ChapterDownloadsScreen> createState() => _ChapterDownloadsScreenState();
}

class _ChapterDownloadsScreenState extends State<ChapterDownloadsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// Show keys the user has expanded. Empty = all collapsed.
  final Set<String> _expanded = <String>{};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggle(String key) => setState(() {
    if (!_expanded.remove(key)) _expanded.add(key);
  });

  bool _matchesQuery(ChapterDownload c) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty ||
        c.showTitle.toLowerCase().contains(q) ||
        c.chapterTitle.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final store = sl<ChapterDownloadStore>();
    final isNovel = widget.mode == ContentMode.novel;
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        isNovel ? l10n.novelDownloads : l10n.mangaDownloads,
      ),
      // Only the box is watched here. The downloader fires per page, and
      // rebuilding a few thousand rows twice a second for a progress bar on one
      // of them is what made this screen crawl — the progress tiles subscribe
      // to it themselves instead.
      body: ValueListenableBuilder<Box<Map>>(
        valueListenable: store.listenable(),
        builder: (context, box, _) {
          final all = store.all();
          if (!all.any((c) => c.mode == widget.mode)) {
            return EmptyState(
              icon: isNovel ? Icons.article_outlined : Icons.menu_book_outlined,
              message: isNovel
                  ? l10n.novelChaptersYouDownloadAppearHere
                  : l10n.mangaChaptersYouDownloadAppearHere,
            );
          }
          final sections = _sections(all, l10n);
          return Column(
            children: [
              _searchField(),
              Expanded(
                // Lazily — a saved series can be thousands of rows, and the
                // eager ListView built every one of them before the first
                // frame.
                child: ListView.builder(
                  itemCount: sections.length,
                  itemBuilder: (context, i) => sections[i](),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// What's running (plus anything that failed, so it can be cleared), then
  /// what's saved grouped by show. [ChapterDownloadStore.all] is already
  /// newest-first, so filling the map in that order puts the newest show's
  /// group first for free.
  List<Widget Function()> _sections(
    List<ChapterDownload> all,
    AppLocalizations l10n,
  ) {
    final downloader = sl<ChapterDownloader>();
    final live = Map<String, ChapterDownload>.fromEntries(
      downloader.inFlight.entries.where((e) => e.value.mode == widget.mode),
    );
    final saved = all
        .where((c) => c.mode == widget.mode)
        .where(_matchesQuery)
        .toList();

    final active = <ChapterDownload>[
      ...live.values.where(_matchesQuery),
      // Not running and not done = a run that died or errored; the box reports
      // both as failed (see ChapterDownload.fromJson).
      ...saved.where(
        (c) =>
            !live.containsKey(c.id) &&
            c.status == ChapterDownloadStatus.failed,
      ),
    ];

    final byShow = <String, List<ChapterDownload>>{};
    for (final c in saved) {
      if (c.status != ChapterDownloadStatus.done) continue;
      (byShow['${c.sourceId}|${c.showId}'] ??= <ChapterDownload>[]).add(c);
    }

    final running = active.where((c) => live.containsKey(c.id)).length;
    final failed = active.length - running;

    return [
      if (active.isNotEmpty) ...[
        () => _sectionHeader(
          l10n.downloadingSection,
          // Cancelling a big queue an X at a time isn't realistic, so the stop
          // lives up here where it covers the lot.
          action: running > 0 ? l10n.stopAllCount(running) : null,
          onAction: running > 0 ? () => _confirmStopAll(running, l10n) : null,
          extra: failed > 0 ? l10n.clearFailedCount(failed) : null,
          onExtra: failed > 0 ? () => _clearFailed(l10n) : null,
        ),
        for (final c in active)
          () => _ChapterProgressTile(id: c.id, fallback: c),
      ],
      if (byShow.isNotEmpty) ...[
        () => _sectionHeader(l10n.downloaded),
        for (final e in byShow.entries)
          () => _ChapterGroup(
            chapters: e.value,
            // Searching reveals the matches instead of making the user expand
            // every group.
            expanded: _query.trim().isNotEmpty || _expanded.contains(e.key),
            onToggle: () => _toggle(e.key),
          ),
      ],
    ];
  }

  Widget _sectionHeader(
    String text, {
    String? action,
    VoidCallback? onAction,
    String? extra,
    VoidCallback? onExtra,
  }) => Padding(
    padding: EdgeInsets.fromLTRB(16, 18, 8, action == null ? 4 : 0),
    child: Row(
      children: [
        Expanded(child: Text(text.toUpperCase(), style: AppText.overline)),
        if (extra != null)
          TextButton(
            onPressed: onExtra,
            child: Text(
              extra,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
        if (action != null)
          TextButton(
            onPressed: onAction,
            child: Text(
              action,
              style: AppText.caption.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    ),
  );

  Future<void> _confirmStopAll(int n, AppLocalizations l10n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.stopDownloading, style: AppText.headline),
        content: Text(
          l10n.stopDownloadingBody(n),
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(
              l10n.keepGoing,
              style: AppText.button.copyWith(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(
              l10n.stopAll,
              style: AppText.button.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await sl<ChapterDownloader>().cancelAll();
  }

  Future<void> _clearFailed(AppLocalizations l10n) async {
    final n = await sl<ChapterDownloader>().clearFailed();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text(l10n.clearedFailedCount(n))),
      );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _query = v),
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: context.l10n.searchDownloads,
          hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
          prefixIcon: const Icon(
            Icons.search_rounded,
            color: AppColors.textTertiary,
          ),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    color: AppColors.textTertiary,
                  ),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: AppColors.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

/// Small glyph that tells a manga chapter from a novel one at a glance.
IconData chapterIcon(ContentMode mode) => mode == ContentMode.novel
    ? Icons.article_rounded
    : Icons.menu_book_rounded;

/// One chapter that's running, queued, or dead. The X cancels a live one and
/// clears a failed one — both end up dropping the record and its files.
class _ChapterProgressTile extends StatelessWidget {
  const _ChapterProgressTile({required this.id, required this.fallback});

  final String id;

  /// Shown once the chapter is no longer running — a failed one, which is the
  /// only other thing that can sit in this section.
  final ChapterDownload fallback;

  @override
  Widget build(BuildContext context) {
    // Subscribing here rather than around the whole list: the downloader ticks
    // per page, and only this row cares.
    return ListenableBuilder(
      listenable: sl<ChapterDownloader>(),
      builder: (context, _) {
        final running = sl<ChapterDownloader>().inFlight[id];
        return _tile(context, running ?? fallback, running != null);
      },
    );
  }

  static String _titleOf(AppLocalizations l10n, ChapterDownload chapter) =>
      chapter.chapterTitle.trim().isEmpty
          ? l10n.chapter
          : chapter.chapterTitle;

  static String _subtitleOf(
    AppLocalizations l10n,
    ChapterDownload chapter,
    bool live,
  ) {
    if (!live) {
      return l10n.showTitleWithError(
        chapter.showTitle,
        chapter.error ?? l10n.downloadFailedStatus,
      );
    }
    if (chapter.status == ChapterDownloadStatus.queued) {
      return l10n.showTitleQueued(chapter.showTitle);
    }
    if (chapter.pageCount > 0) {
      return '${chapter.showTitle} · '
          '${l10n.chapterPagesProgress(chapter.pagesDone, chapter.pageCount)}';
    }
    return l10n.showTitleDownloading(chapter.showTitle);
  }

  Widget _tile(BuildContext context, ChapterDownload chapter, bool live) {
    final l10n = context.l10n;
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      leading: Icon(
        live ? chapterIcon(chapter.mode) : Icons.error_outline_rounded,
        color: AppColors.accent,
        size: 26,
      ),
      title: Text(
        _titleOf(l10n, chapter),
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _subtitleOf(l10n, chapter, live),
            style: AppText.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (live) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: chapter.progress > 0 ? chapter.progress : null,
                minHeight: 3,
                color: AppColors.accent,
                backgroundColor: AppColors.surface2,
              ),
            ),
          ],
        ],
      ),
      trailing: IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: live ? l10n.cancelDownloadTooltip : l10n.removeDownloadTooltip,
        icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
        onPressed: () => unawaited(
          live
              ? sl<ChapterDownloader>().cancel(chapter.id)
              : sl<ChapterDownloadStore>().remove(chapter.id),
        ),
      ),
    );
  }
}

/// Saved chapters of one show — "Title · 3 chapters · 142 MB", collapsed by
/// default.
class _ChapterGroup extends StatelessWidget {
  const _ChapterGroup({
    required this.chapters,
    required this.expanded,
    required this.onToggle,
  });

  final List<ChapterDownload> chapters;
  final bool expanded;
  final VoidCallback onToggle;

  /// Reading order, not download order. Sources that give a chapter number get
  /// sorted by it; the rest fall back to the order they were saved in, oldest
  /// first, which is the closest thing to reading order we have.
  List<ChapterDownload> get ordered {
    final out = [...chapters];
    final numbered = out.every((c) => c.number != null);
    out.sort(
      numbered
          ? (a, b) => a.number!.compareTo(b.number!)
          : (a, b) => a.createdAt.compareTo(b.createdAt),
    );
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final head = chapters.first;
    final bytes = chapters.fold<int>(0, (s, c) => s + c.bytes);
    final n = chapters.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 44,
                    height: 62,
                    // No cover headers on a chapter record, so a Referer-locked
                    // cover just falls through to the placeholder.
                    child: (head.cover != null && head.cover!.isNotEmpty)
                        ? CachedNetworkImage(
                            imageUrl: head.cover!,
                            fit: BoxFit.cover,
                            errorWidget: (c, u, e) =>
                                ColoredBox(color: AppColors.surface2),
                          )
                        : ColoredBox(color: AppColors.surface2),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        head.showTitle,
                        style: AppText.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        l10n.chaptersWithSize(n, fmtDownloadSize(bytes)),
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.textTertiary,
                    size: 22,
                  ),
                  tooltip: l10n.deleteAllChaptersTooltip,
                  onPressed: () => _confirmDeleteAll(context, l10n),
                ),
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          for (final c in ordered)
            _SavedChapterTile(
              chapter: c,
              onTap: () => _openReader(context, ordered, c),
            ),
        const SizedBox(height: 6),
      ],
    );
  }

  Future<void> _confirmDeleteAll(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final n = chapters.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.deleteAllChapters2, style: AppText.headline),
        content: Text(
          l10n.removeAllChaptersOfShow(n, chapters.first.showTitle),
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(
              l10n.cancel,
              style: AppText.button.copyWith(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(
              l10n.deleteAll,
              style: AppText.button.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final store = sl<ChapterDownloadStore>();
    for (final c in chapters) {
      await store.remove(c.id);
    }
  }
}

/// Opens the reader on this show's saved chapters only. Paging past the last
/// downloaded one stops there rather than hitting the network — the point of
/// opening it from here is that it works offline.
void _openReader(
  BuildContext context,
  List<ChapterDownload> ordered,
  ChapterDownload tapped,
) {
  final eps = [
    for (final c in ordered)
      Episode(
        id: c.chapterId,
        title: c.chapterTitle,
        url: c.chapterUrl,
        number: c.number,
      ),
  ];
  final index = ordered.indexWhere((c) => c.id == tapped.id);
  final head = ordered.first;
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => tapped.mode == ContentMode.novel
          ? NovelReaderScreen(
              sourceId: head.sourceId,
              showId: head.showId,
              showTitle: head.showTitle,
              cover: head.cover,
              chapters: eps,
              startIndex: index < 0 ? 0 : index,
            )
          : MangaReaderScreen(
              sourceId: head.sourceId,
              showId: head.showId,
              showTitle: head.showTitle,
              cover: head.cover,
              chapters: eps,
              startIndex: index < 0 ? 0 : index,
            ),
    ),
  );
}

/// One saved chapter — tapping reads it offline.
class _SavedChapterTile extends StatelessWidget {
  const _SavedChapterTile({required this.chapter, required this.onTap});

  final ChapterDownload chapter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      leading: Icon(chapterIcon(chapter.mode), color: AppColors.accent, size: 26),
      title: Text(
        chapter.chapterTitle.trim().isEmpty
            ? l10n.chapter
            : chapter.chapterTitle,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        chapter.bytes > 0 ? fmtDownloadSize(chapter.bytes) : l10n.downloaded,
        style: AppText.caption,
      ),
      trailing: IconButton(
        visualDensity: VisualDensity.compact,
        tooltip: l10n.delete,
        icon: const Icon(
          Icons.delete_outline_rounded,
          color: AppColors.textTertiary,
        ),
        onPressed: () =>
            unawaited(sl<ChapterDownloadStore>().remove(chapter.id)),
      ),
    );
  }
}

String fmtDownloadSize(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  return '$bytes B';
}
