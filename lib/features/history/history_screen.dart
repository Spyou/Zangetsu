import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/aniyomi/aniyomi_image_provider.dart';
import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/reading/read_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/media_info_sheet.dart';
import '../detail/detail_screen.dart';
import '../home/home_screen.dart' show readerFor;
import '../player/player_screen.dart';

/// Full history, newest-first and grouped by day (Today / Yesterday / date),
/// split into three tabs: Anime (watch history, [WatchHistory]) and Manga /
/// Novel (reading history, [ReadHistory] filtered by [ReadEntry.type]). Tap a
/// row to resume, ✕ to remove one, and the toolbar to clear the active tab.
/// Every store is a per-title last-position pointer, so there's one row per
/// show/title.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    this.initialIndex = 0,
    this.showBack = true,
  });

  /// False when shown as a dock tab — nothing to pop back to.
  final bool showBack;

  /// Which tab to open on: 0 Anime, 1 Manga, 2 Novel. Callers pass the current
  /// content mode's index (the [ContentMode] enum is ordered anime/manga/novel)
  /// so opening History from a reading mode lands on the matching tab.
  final int initialIndex;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  final _watch = sl<WatchHistory>();
  final _read = sl<ReadHistory>();
  final _repo = sl<SourceRepository>();
  final _myList = sl<MyListStore>();

  late int _shownIndex = widget.initialIndex.clamp(0, 2);
  late final TabController _tab = TabController(
    length: 3,
    vsync: this,
    initialIndex: _shownIndex,
  )..addListener(_onTabChanged);

  /// Repaint so the "Clear all" action tracks the active tab — but only when
  /// the selected tab actually changes, not on every frame of the slide.
  void _onTabChanged() {
    if (_tab.index != _shownIndex && mounted) {
      setState(() => _shownIndex = _tab.index);
    }
  }

  late List<HistoryEntry> _anime = _watch.all();
  late List<ReadEntry> _manga = _readOf(ProviderType.manga);
  late List<ReadEntry> _novel = _readOf(ProviderType.novel);

  List<ReadEntry> _readOf(ProviderType t) =>
      _read.all().where((e) => e.type == t).toList();

  void _reloadAnime() => setState(() => _anime = _watch.all());
  void _reloadReading() => setState(() {
    final all = _read.all();
    _manga = all.where((e) => e.type == ProviderType.manga).toList();
    _novel = all.where((e) => e.type == ProviderType.novel).toList();
  });

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  // ── Anime (watch history) ─────────────────────────────────────────────────

  MediaItem _stub(HistoryEntry e) => MediaItem(
    id: e.showId,
    title: e.showTitle,
    cover: e.cover,
    coverHeaders: e.coverHeaders,
    url: e.showUrl,
    type: ProviderType.anime,
    sourceId: e.sourceId,
  );

  Future<MediaDetail?> _detailOf(String url, String sourceId) async {
    try {
      return await _repo.detail(url, sourceId: sourceId);
    } catch (_) {
      return null;
    }
  }

  void _openDetail(MediaItem item) {
    Navigator.push(context, DetailScreen.route(item)).then((_) => _reloadAnime());
  }

  /// Long-press info sheet — mirrors the Home Continue Watching card
  /// (Resume, progress, add-to-list, open detail, remove).
  void _showInfo(HistoryEntry e) {
    final stub = _stub(e);
    final pct = (e.progress * 100).round();
    showMediaInfoSheet(
      context,
      title: e.showTitle,
      cover: e.cover,
      headers: e.coverHeaders,
      detail: _detailOf(e.showUrl, e.sourceId),
      inMyList: _myList.contains(stub),
      playLabel: context.l10n.resume,
      progress: e.progress,
      progressLabel: e.episodeNumber != null
          ? context.l10n.episodeWatchedPct(
              e.episodeNumber!.toInt(),
              pct,
            )
          : context.l10n.percentWatched(pct),
      onPlay: () => _resume(e),
      onOpenDetail: () => _openDetail(stub),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: stub,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(stub);
      },
      onRemoveFromContinue: () async {
        await _watch.remove(e.sourceId, e.showId);
        _reloadAnime();
      },
    );
  }

  Future<void> _resume(HistoryEntry e) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          sourceId: e.sourceId,
          episodesResolver: () => _repo.episodes(
            e.showUrl,
            category: e.category,
            sourceId: e.sourceId,
          ),
          resumeEpisodeId: e.episodeId,
          resumeEpisodeNumber: e.episodeNumber,
          resumePosition: e.position,
          resume: sl<ResumeStore>(),
          resolveSources: (u) =>
              _repo.sources(u, sourceId: e.sourceId, fast: true),
          history: _watch,
          showTitle: e.showTitle,
          cover: e.cover,
          coverHeaders: e.coverHeaders,
          showUrl: e.showUrl,
          category: e.category,
          malId: e.malId,
          scrobbleTitle: e.malId != null ? e.showTitle : null,
        ),
      ),
    );
    _reloadAnime();
  }

  Future<void> _remove(HistoryEntry e) async {
    await _watch.remove(e.sourceId, e.showId);
    _reloadAnime();
  }

  // ── Manga / Novel (reading history) ───────────────────────────────────────

  Future<void> _resumeRead(ReadEntry e) async {
    final l10n = context.l10n;
    final chapter = Episode(
      id: e.chapterId,
      title: e.chapterNumber != null
          ? l10n.chapterLabel(e.chapterNumber!.toInt())
          : l10n.chapter,
      number: e.chapterNumber,
      url: e.chapterUrl,
    );
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => readerFor(e, chapter)),
    );
    _reloadReading();
  }

  Future<void> _removeRead(ReadEntry e) async {
    await _read.remove(e.sourceId, e.showId);
    _reloadReading();
  }

  /// Reading sources use `id == url` (both the series path), so a ReadEntry's
  /// [showId] doubles as the detail URL — enough to build a real MediaItem.
  MediaItem _readStub(ReadEntry e) => MediaItem(
    id: e.showId,
    title: e.title,
    cover: e.cover,
    url: e.showId,
    type: e.type,
    sourceId: e.sourceId,
  );

  void _openReadDetail(MediaItem item) {
    Navigator.push(context, DetailScreen.route(item)).then((_) => _reloadReading());
  }

  /// Long-press info sheet for a manga/novel row — the reading twin of
  /// [_showInfo] (cover hero, synopsis, Resume, My List, Details, Remove).
  void _showReadInfo(ReadEntry e) {
    final stub = _readStub(e);
    final hasProgress = e.total > 0;
    final progress = hasProgress ? (e.pos / e.total).clamp(0.0, 1.0) : 0.0;
    final l10n = context.l10n;
    final chap = e.chapterNumber != null
        ? l10n.chapterLabel(e.chapterNumber!.toInt())
        : null;
    final pctLabel =
        hasProgress ? l10n.percentRead((progress * 100).round()) : null;
    showMediaInfoSheet(
      context,
      title: e.title,
      cover: e.cover,
      typeLabel: e.type == ProviderType.manga ? l10n.modeManga : l10n.modeNovel,
      detail: _detailOf(e.showId, e.sourceId),
      inMyList: _myList.contains(stub),
      playLabel: l10n.resume,
      progress: hasProgress ? progress : null,
      progressLabel: [?chap, ?pctLabel].join('  ·  '),
      onPlay: () => _resumeRead(e),
      onOpenDetail: () => _openReadDetail(stub),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: stub,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(stub);
      },
      onRemoveFromContinue: () async {
        await _read.remove(e.sourceId, e.showId);
        _reloadReading();
      },
    );
  }

  // ── Clear-all (acts on the active tab only) ───────────────────────────────

  bool get _activeNotEmpty => switch (_tab.index) {
    0 => _anime.isNotEmpty,
    1 => _manga.isNotEmpty,
    _ => _novel.isNotEmpty,
  };

  Future<void> _clearActiveTab() async {
    final idx = _tab.index;
    // Scoped to the active tab only — clearing one mode never touches the
    // other two. The wording names the exact mode so that's unmistakable.
    final l10n = context.l10n;
    final (noun, kind) = switch (idx) {
      0 => (l10n.historyNounShow, l10n.historyKindWatch),
      1 => (l10n.historyNounMangaItem, l10n.historyKindManga),
      _ => (l10n.historyNounNovelItem, l10n.historyKindNovel),
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.clearKindHistoryTitle(kind)),
        content: Text(l10n.clearKindHistoryBody(noun, kind)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.accent),
            child: Text(l10n.clearAll),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (idx == 0) {
      await _watch.clearAll(); // local + cloud, so it can't sync back
      _reloadAnime();
    } else {
      await _read.clearType(idx == 1 ? ProviderType.manga : ProviderType.novel);
      _reloadReading();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        automaticallyImplyLeading: widget.showBack,
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(context.l10n.history),
        actions: [
          if (_activeNotEmpty)
            IconButton(
              tooltip: context.l10n.clearAll,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearActiveTab,
            ),
        ],
        bottom: TabBar(
          controller: _tab,
          // Drop the default full-width hairline under the bar — that's the
          // "divider" that read badly; the sliding underline is the indicator.
          dividerColor: Colors.transparent,
          dividerHeight: 0,
          // Rounded accent underline hugging the label. The TabController
          // animates it between tabs and crossfades the label colour, so a tap
          // or a swipe glides the underline across.
          indicatorSize: TabBarIndicatorSize.label,
          indicator: UnderlineTabIndicator(
            borderRadius: const BorderRadius.all(Radius.circular(2)),
            borderSide: BorderSide(width: 3, color: AppColors.accent),
            insets: const EdgeInsets.symmetric(horizontal: -6),
          ),
          labelColor: AppColors.accent,
          unselectedLabelColor: AppColors.textSecondary,
          labelStyle: const TextStyle(
            fontFamily: 'Inter',
          fontFamilyFallback: AppText.fontFamilyFallback,
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
          ),
          unselectedLabelStyle: const TextStyle(
            fontFamily: 'Inter',
          fontFamilyFallback: AppText.fontFamilyFallback,
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
          ),
          overlayColor: WidgetStateProperty.all(Colors.transparent),
          tabs: [
            Tab(text: context.l10n.modeStreaming),
            Tab(text: context.l10n.modeManga),
            Tab(text: context.l10n.modeNovel),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _list<HistoryEntry>(
            entries: _anime,
            tsMs: (e) => e.updatedAt,
            row: (e) => _HistoryRow(
              entry: e,
              onTap: () => _resume(e),
              onLongPress: () => _showInfo(e),
              onRemove: () => _remove(e),
            ),
            empty: _EmptyState(
              icon: Icons.history_rounded,
              title: context.l10n.nothingWatchedYet,
              subtitle: context.l10n.showsYouWatchWillAppearHere,
            ),
          ),
          _list<ReadEntry>(
            entries: _manga,
            tsMs: (e) => e.updatedMs,
            row: (e) => _ReadRow(
              entry: e,
              onTap: () => _resumeRead(e),
              onLongPress: () => _showReadInfo(e),
              onRemove: () => _removeRead(e),
            ),
            empty: _EmptyState(
              icon: Icons.auto_stories_outlined,
              title: context.l10n.nothingReadYet,
              subtitle: context.l10n.mangaYouReadWillAppearHere,
            ),
          ),
          _list<ReadEntry>(
            entries: _novel,
            tsMs: (e) => e.updatedMs,
            row: (e) => _ReadRow(
              entry: e,
              onTap: () => _resumeRead(e),
              onLongPress: () => _showReadInfo(e),
              onRemove: () => _removeRead(e),
            ),
            empty: _EmptyState(
              icon: Icons.menu_book_outlined,
              title: context.l10n.nothingReadYet,
              subtitle: context.l10n.novelsYouReadWillAppearHere,
            ),
          ),
        ],
      ),
    );
  }

  /// Day-grouped list for one tab. [tsMs] pulls the epoch-ms timestamp off an
  /// entry so anime ([HistoryEntry.updatedAt]) and reading
  /// ([ReadEntry.updatedMs]) share this scaffolding.
  Widget _list<T>({
    required List<T> entries,
    required int Function(T) tsMs,
    required Widget Function(T) row,
    required Widget empty,
  }) {
    if (entries.isEmpty) return empty;
    final groups = _groupBy(context, entries, tsMs);
    return ListView.builder(
      padding: EdgeInsets.only(
        top: 4,
        bottom: 24 + MediaQuery.paddingOf(context).bottom,
      ),
      itemCount: groups.length,
      itemBuilder: (_, gi) {
        final g = groups[gi];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(
                g.label,
                style: TextStyle(
                  fontFamily: 'Inter',
          fontFamilyFallback: AppText.fontFamilyFallback,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  color: AppColors.accent,
                ),
              ),
            ),
            for (final e in g.entries) row(e),
          ],
        );
      },
    );
  }

  // ── Day grouping ──────────────────────────────────────────────────────────
  List<_DayGroup<T>> _groupBy<T>(
    BuildContext context,
    List<T> entries,
    int Function(T) tsMs,
  ) {
    final out = <_DayGroup<T>>[];
    String? current;
    for (final e in entries) {
      final label = _dayLabel(
        context,
        DateTime.fromMillisecondsSinceEpoch(tsMs(e)),
      );
      if (label != current) {
        out.add(_DayGroup(label, []));
        current = label;
      }
      out.last.entries.add(e);
    }
    return out;
  }
}

class _DayGroup<T> {
  _DayGroup(this.label, this.entries);
  final String label;
  final List<T> entries;
}

String _dayLabel(BuildContext context, DateTime d) {
  final l10n = context.l10n;
  final locale = Localizations.localeOf(context).toString();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return l10n.relativeToday;
  if (diff == 1) return l10n.relativeYesterday;
  if (diff < 7) return DateFormat.E(locale).format(day);
  if (day.year == now.year) {
    return DateFormat('EEE, MMM d', locale).format(day);
  }
  return DateFormat('EEE, MMM d, yyyy', locale).format(day);
}

String _clockTime(BuildContext context, DateTime d) {
  final locale = Localizations.localeOf(context).toString();
  return DateFormat.jm(locale).format(d);
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    required this.onRemove,
  });

  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final time = _clockTime(context, DateTime.fromMillisecondsSinceEpoch(e.updatedAt));
    final ep = e.episodeNumber != null
        ? context.l10n.episodeLabel(e.episodeNumber!.toInt())
        : null;
    final subtitle = [?ep, time].join('  ·  ');
    return _RowShell(
      title: e.showTitle,
      subtitle: subtitle,
      cover: e.cover,
      headers: e.coverHeaders,
      progress: e.progress,
      onTap: onTap,
      onLongPress: onLongPress,
      onRemove: onRemove,
    );
  }
}

class _ReadRow extends StatelessWidget {
  const _ReadRow({
    required this.entry,
    required this.onTap,
    required this.onLongPress,
    required this.onRemove,
  });

  final ReadEntry entry;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final time = _clockTime(context, DateTime.fromMillisecondsSinceEpoch(e.updatedMs));
    final ch = e.chapterNumber != null
        ? context.l10n.chapterLabel(e.chapterNumber!.toInt())
        : null;
    final subtitle = [?ch, time].join('  ·  ');
    final progress = e.total > 0 ? (e.pos / e.total).clamp(0.0, 1.0) : 0.0;
    return _RowShell(
      title: e.title,
      subtitle: subtitle,
      cover: e.cover,
      // ReadEntry stores only a plain cover URL (no per-source headers) — same
      // as the Home Continue Reading card.
      headers: null,
      progress: progress,
      onTap: onTap,
      onLongPress: onLongPress,
      onRemove: onRemove,
    );
  }
}

/// Shared row chrome for both anime and reading history: cover + progress on
/// the left, title/subtitle in the middle, ✕ on the right.
class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.headers,
    required this.progress,
    required this.onTap,
    required this.onRemove,
    this.onLongPress,
  });

  final String title;
  final String subtitle;
  final String? cover;
  final Map<String, String>? headers;
  final double progress;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            _Cover(url: cover, headers: headers, progress: progress),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.headline.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: context.l10n.remove,
              icon: const Icon(
                Icons.close_rounded,
                color: AppColors.textTertiary,
                size: 20,
              ),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// 48×72 rounded cover thumbnail with a thin progress bar pinned to its base.
/// Mirrors [ContinueCard]'s Aniyomi/CachedNetworkImage branching.
class _Cover extends StatelessWidget {
  const _Cover({
    required this.url,
    required this.headers,
    required this.progress,
  });

  final String? url;
  final Map<String, String>? headers;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 48,
        height: 72,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url == null || url!.isEmpty)
              ColoredBox(color: AppColors.surface2)
            else if (headers?['x-ani-src'] != null)
              Image(
                // Resize to the 48×72 thumb's pixel width (matches the
                // non-Aniyomi memCacheWidth) so it isn't cached full-res.
                image: ResizeImage(
                  AniyomiImage(int.parse(headers!['x-ani-src']!), url!),
                  width: 144,
                ),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    ColoredBox(color: AppColors.surface2),
              )
            else
              CachedNetworkImage(
                imageUrl: url!,
                httpHeaders: headers,
                memCacheWidth: 144,
                fit: BoxFit.cover,
                placeholder: (_, _) =>
                    ColoredBox(color: AppColors.surface2),
                errorWidget: (_, _, _) =>
                    ColoredBox(color: AppColors.surface2),
              ),
            if (p > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 3,
                child: Row(
                  children: [
                    Expanded(
                      flex: (p * 1000).round(),
                      child: ColoredBox(color: AppColors.accent),
                    ),
                    Expanded(
                      flex: ((1.0 - p) * 1000).round(),
                      child: const ColoredBox(color: AppColors.hairline),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 56,
              color: AppColors.textTertiary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(title, style: AppText.headline.copyWith(fontSize: 16)),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
