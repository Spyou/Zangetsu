import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/states.dart';
import 'downloads_screen.dart';

/// TV Downloads: a full-screen focusable list of downloaded episodes backed by
/// [DownloadManager]. Mirrors the phone's [DownloadsScreen] layout and data;
/// only the interaction model changes: each episode row is wrapped in
/// [TvFocusable] so D-pad navigates the list and OK plays a completed download
/// via the shared [launchDownloadedEpisode] path.
///
/// The phone [DownloadsScreen] is byte-identical except for the single
/// `if (sl<AppMode>().isTv) return const DownloadsScreenTv();` branch at the
/// top of [DownloadsScreen.build].
class DownloadsScreenTv extends StatelessWidget {
  const DownloadsScreenTv({super.key, this.manager});

  /// Optional [DownloadManager] override — injected in tests to avoid sl/Hive
  /// setup. In production this is always null and [sl<DownloadManager>()] is
  /// used, matching the phone screen's own DI pattern.
  final DownloadManager? manager;

  @override
  Widget build(BuildContext context) {
    final mgr = manager ?? sl<DownloadManager>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Title header ─────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
              child: Text('Downloads', style: AppText.largeTitle),
            ),
            // ── Episode list ─────────────────────────────────────────────────
            Expanded(
              child: ListenableBuilder(
                listenable: mgr,
                builder: (context, _) {
                  final groups = mgr.byShow;
                  if (groups.isEmpty) {
                    return const EmptyState(
                      icon: Icons.download_outlined,
                      message: 'Episodes you download appear here',
                    );
                  }
                  final showIds = groups.keys.toList();
                  // Track whether the very first tile across ALL groups has
                  // been assigned autofocus. Assigned by group index so the
                  // ListView.builder can call itemBuilder idempotently.
                  return ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 32),
                    itemCount: showIds.length,
                    itemBuilder: (context, i) {
                      final recs = groups[showIds[i]]!
                        ..sort(
                          (a, b) =>
                              (a.episodeNumber ?? 0)
                                  .compareTo(b.episodeNumber ?? 0),
                        );
                      return _TvShowGroup(
                        records: recs,
                        manager: mgr,
                        // Only the first group's first tile receives autofocus
                        // so the D-pad starts on a real item, not the rail.
                        autofocusFirst: i == 0,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One show's header + focusable episode tiles for the TV layout.
///
/// The header mirrors [_ShowGroup]'s cover-row exactly (same padding, image
/// size, text styles). The tiles reuse [DownloadTile] unchanged, each wrapped
/// in [TvFocusable] so the D-pad navigates and OK triggers play.
class _TvShowGroup extends StatelessWidget {
  const _TvShowGroup({
    required this.records,
    required this.manager,
    required this.autofocusFirst,
  });

  final List<DownloadRecord> records;
  final DownloadManager manager;

  /// When true the first episode tile in this group gets [TvFocusable.autofocus].
  final bool autofocusFirst;

  @override
  Widget build(BuildContext context) {
    final head = records.first;
    final done = records.where((r) => r.status == DownloadStatus.done).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Show header ─────────────────────────────────────────────────────
        // Mirrors _ShowGroup's Padding/Row exactly so the TV layout is visually
        // identical to the phone list header.
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
        // ── Episode tiles ───────────────────────────────────────────────────
        for (var j = 0; j < records.length; j++)
          TvFocusable(scale: 1.0,
            // First tile of the first group is the initial D-pad target.
            autofocus: autofocusFirst && j == 0,
            // OK opens the action dialog for the row's current status
            // (Play/Pause/Resume/Cancel/Delete as applicable).
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  _TvDownloadActions(record: records[j], manager: manager),
            ),
            // Reuse the phone's tile widget unchanged — only the interaction
            // model changes (D-pad vs touch). The tile's own ListTile.onTap
            // still works for pointer/touch input on hybrid remotes.
            child: DownloadTile(record: records[j], manager: manager),
          ),
        const SizedBox(height: 6),
      ],
    );
  }
}

/// TV action dialog for a single download row: lists only the actions valid
/// for the record's current status, each D-pad focusable. Mirrors the
/// `_TvOptionPicker` pattern in settings_screen_tv.dart.
class _TvDownloadActions extends StatelessWidget {
  const _TvDownloadActions({required this.record, required this.manager});

  final DownloadRecord record;
  final DownloadManager manager;

  List<(String, IconData, VoidCallback)> _actions(BuildContext context) {
    final r = record;
    final out = <(String, IconData, VoidCallback)>[];
    if (r.status == DownloadStatus.done) {
      out.add(('Play', Icons.play_arrow_rounded,
          () => launchDownloadedEpisode(context, r)));
    }
    if (r.status == DownloadStatus.downloading) {
      out.add(('Pause', Icons.pause_rounded, () => unawaited(manager.pause(r))));
    }
    if (r.status == DownloadStatus.paused) {
      out.add(('Resume', Icons.play_arrow_rounded,
          () => unawaited(manager.resume(r))));
    }
    if (r.isActive) {
      out.add(('Cancel', Icons.close_rounded, () => unawaited(manager.delete(r))));
    }
    out.add(('Delete', Icons.delete_outline_rounded,
        () => unawaited(manager.delete(r))));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final actions = _actions(context);
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
      child: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Text(
                record.episodeTitle.isNotEmpty
                    ? record.episodeTitle
                    : record.showTitle,
                style: AppText.title.copyWith(color: AppColors.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            for (int i = 0; i < actions.length; i++)
              TvFocusable(
                autofocus: i == 0,
                onTap: () {
                  Navigator.of(context).pop();
                  actions[i].$3();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  child: Row(
                    children: [
                      Icon(actions[i].$2, color: AppColors.textPrimary, size: 22),
                      const SizedBox(width: 16),
                      Text(actions[i].$1, style: AppText.headline),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Test-only handle to the private TV download action dialog.
@visibleForTesting
Widget debugTvDownloadActions({
  required DownloadRecord record,
  required DownloadManager manager,
}) =>
    _TvDownloadActions(record: record, manager: manager);
