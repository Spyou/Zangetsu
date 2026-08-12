import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_prefs.dart';
import '../../core/download/download_record.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/states.dart';
import '../settings/download_location_screen.dart' show folderLabelFromUri;
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
    // With nothing downloaded there's no episode tile to hold initial focus, so
    // the location header autofocuses instead — keeping it D-pad reachable.
    final noDownloads = mgr.byShow.isEmpty;
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
            // ── Download-location header (folder picker) ─────────────────────
            _TvLocationHeader(autofocus: noDownloads),
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
                    const SizedBox(height: 2),
                    Text(
                      '$done of ${records.length} downloaded',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              TvFocusable(
                scale: 1.1,
                semanticLabel: 'Delete all episodes',
                onTap: () => _confirmDeleteAllTv(context),
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    color: AppColors.textTertiary,
                    size: 24,
                  ),
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

  /// D-pad confirm, then wipe every episode of this show. Defaults focus to
  /// Cancel so a stray OK press can't delete a whole show.
  Future<void> _confirmDeleteAllTv(BuildContext context) async {
    final n = records.length;
    await showDialog<void>(
      context: context,
      builder: (dctx) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
        child: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 6),
                child: Text(
                  'Delete all downloads?',
                  style: AppText.title.copyWith(color: AppColors.textPrimary),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Text(
                  'Remove all $n ${n == 1 ? 'episode' : 'episodes'} of '
                  '“${records.first.showTitle}” from this device?',
                  style: AppText.body,
                ),
              ),
              const Divider(height: 1, color: AppColors.hairline),
              TvFocusable(
                autofocus: true,
                onTap: () => Navigator.of(dctx).pop(),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  child: Row(
                    children: [
                      Icon(Icons.close_rounded,
                          color: AppColors.textPrimary, size: 22),
                      SizedBox(width: 16),
                      Text('Cancel', style: AppText.headline),
                    ],
                  ),
                ),
              ),
              TvFocusable(
                onTap: () {
                  Navigator.of(dctx).pop();
                  unawaited(manager.deleteAll(records));
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline_rounded,
                          color: AppColors.accent, size: 22),
                      const SizedBox(width: 16),
                      Text(
                        'Delete all',
                        style: AppText.headline.copyWith(color: AppColors.accent),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
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
    if (r.status == DownloadStatus.failed && !r.isTorrent) {
      out.add(('Retry', Icons.refresh_rounded, () => unawaited(manager.retry(r))));
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

/// Focusable "Saving to: `<folder>` · Change" row for the TV Downloads screen —
/// the phone's location header (`_locationHeader` in downloads_screen.dart) has
/// no TV equivalent, so this surfaces the same custom-folder picker for D-pad.
/// Opens [_TvLocationPicker] and refreshes its label when it closes.
class _TvLocationHeader extends StatefulWidget {
  const _TvLocationHeader({required this.autofocus});

  /// Autofocus this row when the screen has no episode tiles to hold focus.
  final bool autofocus;

  @override
  State<_TvLocationHeader> createState() => _TvLocationHeaderState();
}

class _TvLocationHeaderState extends State<_TvLocationHeader> {
  @override
  Widget build(BuildContext context) {
    // Guard the DI lookup so widget tests (which inject a fake manager and skip
    // GetIt) still render the header with the default label.
    final label = (sl.isRegistered<DownloadPrefs>()
            ? sl<DownloadPrefs>().locationLabel
            : null) ??
        'Download › Zangetsu';
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 0, 48, 12),
      child: TvFocusable(
        autofocus: widget.autofocus,
        semanticLabel: 'Change download folder',
        onTap: () async {
          await showDialog<void>(
            context: context,
            builder: (_) => const _TvLocationPicker(),
          );
          if (mounted) setState(() {}); // reflect a newly picked folder
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_rounded,
                  color: AppColors.textSecondary, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Saving to', style: AppText.caption),
                    const SizedBox(height: 2),
                    Text(label,
                        style: AppText.body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text('Change',
                  style: AppText.body.copyWith(color: AppColors.accent)),
            ],
          ),
        ),
      ),
    );
  }
}

/// TV dialog to pick a custom download folder (or reset to default). Reuses the
/// exact SAF picker + label helper the phone screen uses, wrapped in
/// [TvFocusable] so it works with a remote. Note: the folder picker relies on
/// the Android system document UI, which some TVs don't ship — if nothing opens,
/// the TV has no SAF picker and the default location stays in use.
class _TvLocationPicker extends StatefulWidget {
  const _TvLocationPicker();

  @override
  State<_TvLocationPicker> createState() => _TvLocationPickerState();
}

class _TvLocationPickerState extends State<_TvLocationPicker> {
  // Detected drives (internal + USB/SSD/SD) — the CloudStream-style list that
  // works on TV without a SAF picker. Loaded async from the native side.
  List<({String path, String label, bool removable})> _volumes = const [];

  @override
  void initState() {
    super.initState();
    _loadVolumes();
  }

  Future<void> _loadVolumes() async {
    if (!sl.isRegistered<DownloadManager>()) return;
    final v = await sl<DownloadManager>().listDownloadVolumes();
    if (mounted) setState(() => _volumes = v);
  }

  Future<void> _select(String? path, String? label) async {
    final nav = Navigator.of(context);
    await sl<DownloadPrefs>().setLocation(path, label);
    if (mounted) nav.pop();
  }

  Future<void> _pickSaf() async {
    final nav = Navigator.of(context);
    Uri? uri;
    try {
      uri = await FileDownloader().uri.pickDirectory(persistedUriPermission: true);
    } catch (_) {
      uri = null; // no SAF picker on this TV — leave the current location
    }
    if (uri == null) return; // canceled or unavailable
    await sl<DownloadPrefs>()
        .setLocation(uri.toString(), folderLabelFromUri(uri));
    if (mounted) nav.pop();
  }

  Widget _row({
    required IconData icon,
    required String title,
    String? subtitle,
    required bool autofocus,
    required VoidCallback onTap,
    bool selected = false,
  }) {
    final tint = selected ? AppColors.accent : AppColors.textPrimary;
    return TvFocusable(
      autofocus: autofocus,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: tint, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppText.headline.copyWith(color: tint),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: AppText.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, color: AppColors.accent, size: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefs = sl.isRegistered<DownloadPrefs>() ? sl<DownloadPrefs>() : null;
    final current = prefs?.locationUri;
    final hasCustom = current != null;

    // Build the option rows; the first one gets autofocus so the D-pad lands on
    // a real target. Detected drives first, then SAF custom, then reset.
    final rows = <Widget>[];
    for (final v in _volumes) {
      rows.add(_row(
        icon: v.removable
            ? Icons.sd_storage_rounded
            : Icons.smartphone_rounded,
        title: v.label,
        subtitle: v.removable ? 'Removable drive' : 'On this device',
        autofocus: rows.isEmpty,
        selected: current == v.path,
        onTap: () => _select(v.path, v.label),
      ));
    }
    rows.add(_row(
      icon: Icons.folder_open_outlined,
      title: 'Choose folder…',
      subtitle: 'Needs a file-manager app on the TV',
      autofocus: rows.isEmpty,
      onTap: _pickSaf,
    ));
    if (hasCustom) {
      rows.add(_row(
        icon: Icons.restore_rounded,
        title: 'Reset to default',
        autofocus: false,
        onTap: () => _select(null, null),
      ));
    }

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 40),
      child: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 6),
              child: Text('Download location',
                  style: AppText.title.copyWith(color: AppColors.textPrimary)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(prefs?.locationLabel ?? 'Download › Zangetsu',
                  style: AppText.body),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            ...rows,
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
