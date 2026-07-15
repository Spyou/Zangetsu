import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/aniyomi/aniyomi_image_provider.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/media_info_sheet.dart';
import '../detail/detail_screen.dart';
import '../player/player_screen.dart';

/// Full watch history — every show you've watched, newest-first, grouped by
/// day (Today / Yesterday / date). Tap a row to resume, ✕ to remove one, and
/// the toolbar to clear everything. Per-show (one entry per show, last episode
/// + progress), backed by [WatchHistory].
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _history = sl<WatchHistory>();
  final _repo = sl<SourceRepository>();
  final _myList = sl<MyListStore>();
  late List<HistoryEntry> _entries = _history.all();

  void _reload() => setState(() => _entries = _history.all());

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
    Navigator.push(context, DetailScreen.route(item)).then((_) => _reload());
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
      playLabel: 'Resume',
      progress: e.progress,
      progressLabel: e.episodeNumber != null
          ? 'Episode ${e.episodeNumber!.toInt()} · $pct% watched'
          : '$pct% watched',
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
        await _history.remove(e.sourceId, e.showId);
        _reload();
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
          history: _history,
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
    _reload();
  }

  Future<void> _remove(HistoryEntry e) async {
    await _history.remove(e.sourceId, e.showId);
    _reload();
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Clear history?'),
        content: const Text(
          'This removes every show from your watch history. Your list and '
          'downloads are untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.accent),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _history.clearLocal();
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _group(_entries);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        surfaceTintColor: Colors.transparent,
        title: const Text('History'),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              tooltip: 'Clear all',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _entries.isEmpty
          ? const _EmptyHistory()
          : ListView.builder(
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
                        style: const TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                    for (final e in g.entries)
                      _HistoryRow(
                        entry: e,
                        onTap: () => _resume(e),
                        onLongPress: () => _showInfo(e),
                        onRemove: () => _remove(e),
                      ),
                  ],
                );
              },
            ),
    );
  }

  // ── Day grouping ──────────────────────────────────────────────────────────
  List<_DayGroup> _group(List<HistoryEntry> entries) {
    final out = <_DayGroup>[];
    String? current;
    for (final e in entries) {
      final label = _dayLabel(
        DateTime.fromMillisecondsSinceEpoch(e.updatedAt),
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

class _DayGroup {
  _DayGroup(this.label, this.entries);
  final String label;
  final List<HistoryEntry> entries;
}

const _monShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _wdShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _dayLabel(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff < 7) return _wdShort[day.weekday - 1];
  final y = day.year == now.year ? '' : ', ${day.year}';
  return '${_wdShort[day.weekday - 1]}, ${_monShort[day.month - 1]} ${day.day}$y';
}

String _clockTime(DateTime d) {
  final h24 = d.hour;
  final h = h24 % 12 == 0 ? 12 : h24 % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${h24 < 12 ? 'AM' : 'PM'}';
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
    final time = _clockTime(DateTime.fromMillisecondsSinceEpoch(e.updatedAt));
    final ep = e.episodeNumber != null
        ? 'Episode ${e.episodeNumber!.toInt()}'
        : null;
    final subtitle = [?ep, time].join('  ·  ');
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            _Cover(url: e.cover, headers: e.coverHeaders, progress: e.progress),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    e.showTitle,
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
              tooltip: 'Remove',
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
              const ColoredBox(color: AppColors.surface2)
            else if (headers?['x-ani-src'] != null)
              Image(
                image: AniyomiImage(int.parse(headers!['x-ani-src']!), url!),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: AppColors.surface2),
              )
            else
              CachedNetworkImage(
                imageUrl: url!,
                httpHeaders: headers,
                memCacheWidth: 144,
                fit: BoxFit.cover,
                placeholder: (_, _) =>
                    const ColoredBox(color: AppColors.surface2),
                errorWidget: (_, _, _) =>
                    const ColoredBox(color: AppColors.surface2),
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
                      child: const ColoredBox(color: AppColors.accent),
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

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_rounded,
              size: 56,
              color: AppColors.textTertiary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 16),
            Text(
              'Nothing watched yet',
              style: AppText.headline.copyWith(fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              'Shows you watch will appear here so you can pick up where you '
              'left off.',
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
