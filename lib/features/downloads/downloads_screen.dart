import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import '../player/player_screen.dart';

/// Offline library — downloads grouped by show, with per-episode progress and
/// actions (play / pause / resume / cancel / delete).
class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
          final showIds = groups.keys.toList();
          return ListView.builder(
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            itemCount: showIds.length,
            itemBuilder: (context, i) {
              final recs = groups[showIds[i]]!
                ..sort(
                  (a, b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0),
                );
              return _ShowGroup(records: recs, manager: manager);
            },
          );
        },
      ),
    );
  }
}

class _ShowGroup extends StatelessWidget {
  const _ShowGroup({required this.records, required this.manager});
  final List<DownloadRecord> records;
  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final head = records.first;
    final done = records.where((r) => r.status == DownloadStatus.done).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
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
                      '$done of ${records.length} downloaded',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        for (final r in records) _DownloadTile(record: r, manager: manager),
        const SizedBox(height: 6),
      ],
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({required this.record, required this.manager});
  final DownloadRecord record;
  final DownloadManager manager;

  String get _epLabel {
    final n = record.episodeNumber?.toInt();
    final base = n != null ? 'E$n' : 'Episode';
    final t = record.episodeTitle.trim();
    return (t.isEmpty || t == base) ? base : '$base · $t';
  }

  String get _subtitle => switch (record.status) {
    DownloadStatus.done =>
      record.bytesTotal > 0 ? _fmtSize(record.bytesTotal) : 'Downloaded',
    DownloadStatus.downloading =>
      '${(record.progress * 100).round()}%'
          '${record.bytesTotal > 0 ? ' of ${_fmtSize(record.bytesTotal)}' : ''}',
    DownloadStatus.paused => 'Paused · ${(record.progress * 100).round()}%',
    DownloadStatus.queued => 'Queued',
    DownloadStatus.resolving => 'Preparing…',
    DownloadStatus.unsupported => record.error ?? 'Not available offline yet',
    DownloadStatus.failed => record.error ?? 'Failed',
    DownloadStatus.canceled => 'Canceled',
  };

  Future<void> _play(BuildContext context) async {
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
          resolveSources: (_) async =>
              [VideoSource(url: path, container: SourceContainer.mp4)],
          history: sl<WatchHistory>(),
          showTitle: record.showTitle,
          cover: record.cover,
          coverHeaders: record.coverHeaders,
          showUrl: record.showUrl,
          category: record.category,
        ),
      ),
    );
  }

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
          case 'cancel':
            unawaited(manager.cancel(r));
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
