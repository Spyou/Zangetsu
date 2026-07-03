import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/torrent/torrent_download_service.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import '../player/player_screen.dart';
import 'downloads_screen_tv.dart';

/// Offline library — downloads grouped by show, with per-episode progress and
/// actions (play / pause / resume / cancel / delete). Shows collapse by default
/// into a scannable list; a search box filters by show or episode title, and a
/// summary strip shows the total downloaded count + storage used.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// Show ids the user has expanded. Empty = all collapsed (the default).
  final Set<String> _expanded = <String>{};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggle(String showId) => setState(() {
    if (!_expanded.remove(showId)) _expanded.add(showId);
  });

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const DownloadsScreenTv();
    final manager = sl<DownloadManager>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('Downloads', style: AppText.title)),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final groups = manager.byShow;
          if (groups.isEmpty) {
            return const EmptyState(
              icon: Icons.download_outlined,
              message: 'Episodes you download appear here',
            );
          }
          return Column(
            children: [
              _searchField(),
              Expanded(child: _list(groups, manager)),
            ],
          );
        },
      ),
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: TextField(
        controller: _searchCtrl,
        onChanged: (v) => setState(() => _query = v),
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search downloads',
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

  Widget _list(
    Map<String, List<DownloadRecord>> groups,
    DownloadManager manager,
  ) {
    final q = _query.trim().toLowerCase();
    final all = manager.all;
    final done = all.where((r) => r.status == DownloadStatus.done).toList();
    final totalBytes = done.fold<int>(0, (s, r) => s + r.bytesTotal);

    final showIds = groups.keys.toList();
    final rows = <Widget>[];
    for (final id in showIds) {
      final recs = [...groups[id]!]
        ..sort((a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0));
      final head = recs.first;

      List<DownloadRecord> episodes = recs;
      var forceExpand = false;
      if (q.isNotEmpty) {
        final showMatch = head.showTitle.toLowerCase().contains(q);
        if (!showMatch) {
          episodes = recs
              .where((r) => _episodeSearchText(r).contains(q))
              .toList();
          if (episodes.isEmpty) continue; // this show has no match — hide it
        }
        forceExpand = true; // reveal matches while searching
      }

      rows.add(
        _ShowGroup(
          records: recs,
          episodes: episodes,
          manager: manager,
          expanded: forceExpand || _expanded.contains(id),
          onToggle: () => _toggle(id),
        ),
      );
    }

    if (rows.isEmpty) {
      return const EmptyState(
        icon: Icons.search_off_rounded,
        message: 'No downloads match your search',
      );
    }

    final anyExpanded = showIds.any(_expanded.contains);
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        _summaryStrip(
          count: done.length,
          bytes: totalBytes,
          anyExpanded: anyExpanded,
          onToggleAll: () => setState(() {
            if (anyExpanded) {
              _expanded.clear();
            } else {
              _expanded.addAll(showIds);
            }
          }),
        ),
        ...rows,
      ],
    );
  }

  Widget _summaryStrip({
    required int count,
    required int bytes,
    required bool anyExpanded,
    required VoidCallback onToggleAll,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 2),
      child: Row(
        children: [
          const Icon(
            Icons.folder_outlined,
            size: 15,
            color: AppColors.textTertiary,
          ),
          const SizedBox(width: 6),
          Text(
            '$count downloaded · ${_fmtSize(bytes)}',
            style: AppText.caption,
          ),
          const Spacer(),
          TextButton(
            onPressed: onToggleAll,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accent,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              anyExpanded ? 'Collapse all' : 'Expand all',
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lowercased text a download is matched against when searching.
String _episodeSearchText(DownloadRecord r) {
  final n = r.episodeNumber?.toInt();
  return 'e${n ?? ''} ${r.episodeTitle}'.toLowerCase();
}

class _ShowGroup extends StatelessWidget {
  const _ShowGroup({
    required this.records,
    required this.episodes,
    required this.manager,
    required this.expanded,
    required this.onToggle,
  });

  /// The full group — drives the "done of total" count and the group size.
  final List<DownloadRecord> records;

  /// The episodes to render when expanded (a filtered subset while searching).
  final List<DownloadRecord> episodes;

  final DownloadManager manager;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final head = records.first;
    final doneRecs =
        records.where((r) => r.status == DownloadStatus.done).toList();
    final groupBytes = doneRecs.fold<int>(0, (s, r) => s + r.bytesTotal);
    final sizeSuffix = groupBytes > 0 ? ' · ${_fmtSize(groupBytes)}' : '';
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
                    child: (head.cover != null && head.cover!.isNotEmpty)
                        ? CachedNetworkImage(
                            imageUrl: head.cover!,
                            httpHeaders: head.coverHeaders,
                            fit: BoxFit.cover,
                            errorWidget: (c, u, e) =>
                                const ColoredBox(color: AppColors.surface2),
                          )
                        : const ColoredBox(color: AppColors.surface2),
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
                      const SizedBox(height: 2),
                      Text(
                        '${doneRecs.length} of ${records.length}$sizeSuffix',
                        style: AppText.caption,
                      ),
                    ],
                  ),
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
          for (final r in episodes) DownloadTile(record: r, manager: manager),
        const SizedBox(height: 6),
      ],
    );
  }
}

/// Launches playback of a completed [DownloadRecord] via [PlayerScreen].
/// Called by both [DownloadTile] (phone touch path) and [DownloadsScreenTv]
/// (TV D-pad OK path) so the play logic lives in one place.
Future<void> launchDownloadedEpisode(
  BuildContext context,
  DownloadRecord record,
) async {
  final path = record.filePath;
  if (path == null) return;
  final ep = Episode(
    id: record.episodeId,
    title: record.episodeTitle,
    number: record.episodeNumber,
    url: record.episodeUrl,
  );
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        sourceId: record.sourceId,
        episodes: [ep],
        startIndex: 0,
        resume: sl<ResumeStore>(),
        resolveSources: (_) async => [
          VideoSource(
            url: path,
            container: SourceContainer.mp4,
            // Soft subs saved next to the video (e.g. HiAnime) → load from disk.
            subtitles: [
              for (final s in record.subtitles)
                Subtitle(
                  url: s.path,
                  lang: s.lang,
                  label: s.label,
                  isDefault: s.isDefault,
                ),
            ],
          ),
        ],
        history: sl<WatchHistory>(),
        showTitle: record.showTitle,
        cover: record.cover,
        coverHeaders: record.coverHeaders,
        showUrl: record.showUrl,
        category: record.category,
        malId: record.malId,
        scrobbleTitle: record.malId != null ? record.showTitle : null,
      ),
    ),
  );
}

class DownloadTile extends StatelessWidget {
  const DownloadTile({super.key, required this.record, required this.manager});
  final DownloadRecord record;
  final DownloadManager manager;

  String get _epLabel {
    final n = record.episodeNumber?.toInt();
    final base = n != null ? 'E$n' : 'Episode';
    final t = record.episodeTitle.trim();
    return (t.isEmpty || t == base) ? base : '$base · $t';
  }

  String get _subtitle {
    // A finished torrent is streamed into the user's folder — surface that phase.
    if (record.isTorrent &&
        manager.torrentProgress[record.id]?.status == 'copying') {
      return 'Saving to your folder…';
    }
    return switch (record.status) {
      DownloadStatus.done =>
        record.bytesTotal > 0 ? _fmtSize(record.bytesTotal) : 'Downloaded',
      DownloadStatus.downloading =>
        '${(record.progress * 100).round()}%'
            '${record.bytesTotal > 0 ? ' of ${_fmtSize(record.bytesTotal)}' : ''}'
            '$_torrentSuffix',
      DownloadStatus.paused => 'Paused · ${(record.progress * 100).round()}%',
      DownloadStatus.queued => 'Queued',
      DownloadStatus.resolving => 'Preparing…',
      DownloadStatus.unsupported => record.error ?? 'Not available offline yet',
      DownloadStatus.failed => record.error ?? 'Failed',
      DownloadStatus.canceled => 'Canceled',
    };
  }

  /// " · N peers · X MB/s" for an active torrent download (empty otherwise).
  String get _torrentSuffix {
    if (!record.isTorrent) return '';
    final TorrentDownloadProgress? p = manager.torrentProgress[record.id];
    if (p == null) return '';
    final parts = <String>[];
    if (p.peers > 0) parts.add('${p.peers} peers');
    if (p.downSpeedBps > 0) {
      final mb = p.downSpeedBps / (1024 * 1024);
      parts.add(mb >= 1
          ? '${mb.toStringAsFixed(1)} MB/s'
          : '${(p.downSpeedBps / 1024).round()} KB/s');
    }
    return parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
  }

  Future<void> _play(BuildContext context) =>
      launchDownloadedEpisode(context, record);

  @override
  Widget build(BuildContext context) {
    final isDone = record.status == DownloadStatus.done;
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      onTap: isDone ? () => _play(context) : null,
      leading: _StatusGlyph(record: record),
      title: Text(
        _epLabel,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_subtitle, style: AppText.caption),
          if (record.status == DownloadStatus.downloading ||
              record.status == DownloadStatus.paused) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: record.progress > 0 ? record.progress : null,
                minHeight: 3,
                color: AppColors.accent,
                backgroundColor: AppColors.surface2,
              ),
            ),
          ],
        ],
      ),
      trailing: _TileMenu(record: record, manager: manager),
    );
  }
}

class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.record});
  final DownloadRecord record;

  @override
  Widget build(BuildContext context) {
    return switch (record.status) {
      DownloadStatus.done => const Icon(
        Icons.play_circle_fill_rounded,
        color: AppColors.accent,
        size: 32,
      ),
      DownloadStatus.downloading => SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(
          value: record.progress > 0 ? record.progress : null,
          strokeWidth: 2.4,
          color: AppColors.accent,
          backgroundColor: AppColors.surface2,
        ),
      ),
      DownloadStatus.paused => const Icon(
        Icons.pause_circle_outline_rounded,
        color: AppColors.textSecondary,
        size: 30,
      ),
      DownloadStatus.unsupported => const Icon(
        Icons.cloud_off_outlined,
        color: AppColors.textTertiary,
        size: 26,
      ),
      DownloadStatus.failed => const Icon(
        Icons.error_outline_rounded,
        color: AppColors.accent,
        size: 28,
      ),
      DownloadStatus.canceled => const Icon(
        Icons.cancel_outlined,
        color: AppColors.textTertiary,
        size: 26,
      ),
      // queued / resolving — genuinely loading.
      _ => const SizedBox(
        width: 26,
        height: 26,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    };
  }
}

class _TileMenu extends StatelessWidget {
  const _TileMenu({required this.record, required this.manager});
  final DownloadRecord record;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final r = record;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert_rounded, color: AppColors.textSecondary),
      color: AppColors.surface2,
      onSelected: (v) {
        switch (v) {
          case 'pause':
            unawaited(manager.pause(r));
          case 'resume':
            unawaited(manager.resume(r));
          // Cancel an in-flight download = stop it AND remove it from the list
          // (delete cancels the task, drops the record, and clears fallbacks).
          case 'cancel':
          case 'delete':
            unawaited(manager.delete(r));
        }
      },
      itemBuilder: (context) => [
        if (r.status == DownloadStatus.downloading)
          _item('pause', Icons.pause_rounded, 'Pause'),
        if (r.status == DownloadStatus.paused)
          _item('resume', Icons.play_arrow_rounded, 'Resume'),
        if (r.isActive) _item('cancel', Icons.close_rounded, 'Cancel'),
        _item('delete', Icons.delete_outline_rounded, 'Delete'),
      ],
    );
  }

  PopupMenuItem<String> _item(String value, IconData icon, String label) =>
      PopupMenuItem<String>(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.textPrimary),
            const SizedBox(width: 12),
            Text(label, style: AppText.body.copyWith(color: AppColors.textPrimary)),
          ],
        ),
      );
}

String _fmtSize(int bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
  if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  return '$bytes B';
}
