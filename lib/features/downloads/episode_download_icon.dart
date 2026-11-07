import 'package:flutter/material.dart';
import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';

class EpisodeDownloadIcon extends StatelessWidget {
  const EpisodeDownloadIcon({
    super.key,
    required this.sourceId,
    required this.showId,
    required this.episodeId,
    required this.onTap,
  });

  final String sourceId;
  final String showId;
  final String episodeId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final manager = sl<DownloadManager>();
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final rec = manager.recordFor(sourceId, showId, episodeId);
        final s = rec?.status;
        // While a download is live (or paused/queued/resolving), tapping the ring
        // opens a Pause/Cancel menu instead of re-opening the server picker.
        final inProgress =
            rec != null &&
            (s == DownloadStatus.downloading ||
                s == DownloadStatus.paused ||
                s == DownloadStatus.queued ||
                s == DownloadStatus.resolving);
        return _glyph(
          context.l10n,
          s,
          rec?.progress ?? 0,
          onPressed: inProgress
              ? () => showDownloadMenu(context, manager, rec)
              : onTap,
        );
      },
    );
  }

  Widget _glyph(
    AppLocalizations l10n,
    DownloadStatus? status,
    double progress, {
    required VoidCallback onPressed,
  }) {
    final child = switch (status) {
      DownloadStatus.done => Icon(
        Icons.download_done_rounded,
        color: AppColors.accent,
        size: 24,
      ),
      DownloadStatus.downloading || DownloadStatus.paused => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          value: progress > 0 ? progress : null,
          strokeWidth: 2.4,
          color: AppColors.accent,
          backgroundColor: AppColors.surface2,
        ),
      ),
      DownloadStatus.queued || DownloadStatus.resolving => const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.textSecondary,
        ),
      ),
      DownloadStatus.unsupported => const Icon(
        Icons.cloud_off_outlined,
        color: AppColors.textTertiary,
        size: 22,
      ),
      DownloadStatus.failed => Icon(
        Icons.refresh_rounded,
        color: AppColors.accent,
        size: 24,
      ),
      // null (never downloaded) or canceled → offer to download.
      _ => const Icon(
        Icons.file_download_outlined,
        color: AppColors.textPrimary,
        size: 24,
      ),
    };
    final label = switch (status) {
      DownloadStatus.done => l10n.downloaded,
      DownloadStatus.downloading || DownloadStatus.paused => l10n.downloading,
      DownloadStatus.queued || DownloadStatus.resolving => l10n.downloading,
      DownloadStatus.unsupported => l10n.downloadUnsupported,
      DownloadStatus.failed => l10n.retryDownload,
      _ => l10n.downloadEpisode,
    };
    return IconButton(
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      splashRadius: 22,
      tooltip: label,
      icon: child,
    );
  }

  // Tap on a live download's ring → a small Pause/Resume + Cancel sheet, rather
  // than the server picker (which only makes sense before a download starts).
  static void showDownloadMenu(
    BuildContext context,
    DownloadManager manager,
    DownloadRecord rec,
  ) {
    final l10n = context.l10n;
    final paused = rec.status == DownloadStatus.paused;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      barrierColor: Colors.black54,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                color: AppColors.textPrimary,
              ),
              title: Text(
                paused ? l10n.resumeDownload : l10n.pauseDownload,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                if (paused) {
                  manager.resume(rec);
                } else {
                  manager.pause(rec);
                }
              },
            ),
            ListTile(
              leading: Icon(Icons.close_rounded, color: AppColors.accent),
              title: Text(
                l10n.cancelDownload,
                style: AppText.body.copyWith(color: AppColors.accent),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                manager.cancel(rec);
              },
            ),
          ],
        ),
      ),
    );
  }
}
