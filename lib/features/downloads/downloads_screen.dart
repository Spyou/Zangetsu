import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import '../../core/ui/settings_widgets.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/download/chapter_download_store.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_prefs.dart';
import '../../core/download/download_record.dart';
import '../../core/mode/content_mode.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/torrent/torrent_download_service.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import '../../l10n/l10n.dart';
import '../settings/download_location_screen.dart';
import '../player/player_screen.dart';
import '../player/tv_playback_launch.dart';
import 'chapter_downloads_screen.dart';
import 'downloads_screen_tv.dart';

/// Offline library — downloads grouped by show, with per-episode progress and
/// actions (play / pause / resume / cancel / delete). Shows collapse by default
/// into a scannable list; a search box filters by show or episode title, and a
/// summary strip shows the total downloaded count + storage used.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key, this.showBack = true});

  /// False when shown as a dock tab — see [settingsAppBar].
  final bool showBack;

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen>
    with WidgetsBindingObserver {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// Show ids the user has expanded. Empty = all collapsed (the default).
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prune();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from a file manager (where a file may have been deleted) →
    // reconcile the list with disk. This is the case initState alone missed.
    if (state == AppLifecycleState.resumed) _prune();
  }

  /// Drop downloads whose file was deleted outside the app. Non-blocking.
  void _prune() => unawaited(sl<DownloadManager>().pruneMissing());

  void _toggle(String showId) => setState(() {
    if (!_expanded.remove(showId)) _expanded.add(showId);
  });

  /// "Saving to: `folder` · Change" — surfaces the download location right here
  /// (opens the existing picker) instead of only burying it in Settings.
  Widget _locationHeader() {
    final l10n = context.l10n;
    final label = sl<DownloadPrefs>().locationLabel ?? l10n.downloadsZangetsu;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
      child: Row(
        children: [
          const Icon(
            Icons.folder_outlined,
            size: 18,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.savingTo,
                  style: AppText.caption.copyWith(color: AppColors.textTertiary),
                ),
                Text(
                  label,
                  style: AppText.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const DownloadLocationScreen(),
                ),
              );
              if (mounted) setState(() {}); // refresh the shown folder
            },
            child: Text(
              l10n.change,
              style: AppText.body.copyWith(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Bottom sheet with the CloudStream-style download concurrency sliders.
  /// Applies to the NEXT downloads started (running HLS jobs aren't retimed).
  void _openDownloadSettings() {
    final l10n = context.l10n;
    final prefs = sl<DownloadPrefs>();
    // Hold the live drag value in local state so the sliders move smoothly —
    // each tick isn't an async Hive write/read round-trip. Persist + apply on
    // release (onCommit).
    int parallel = prefs.parallelDownloads;
    int connections = prefs.connectionsPerDownload;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget slider({
            required String title,
            required String subtitle,
            required int value,
            required int min,
            required int max,
            required ValueChanged<int> onChanged,
            ValueChanged<int>? onCommit,
          }) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Row(
                    children: [
                      Expanded(child: Text(title, style: AppText.headline)),
                      Text('$value', style: AppText.headline.copyWith(
                        color: AppColors.accent,
                      )),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                  child: Text(subtitle, style: AppText.caption),
                ),
                Slider(
                  value: value.toDouble(),
                  min: min.toDouble(),
                  max: max.toDouble(),
                  divisions: max - min,
                  activeColor: AppColors.accent,
                  label: '$value',
                  onChanged: (v) => setSheet(() => onChanged(v.round())),
                  onChangeEnd: onCommit == null
                      ? null
                      : (v) => onCommit(v.round()),
                ),
              ],
            );
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 4),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(l10n.downloadSettings, style: AppText.title),
                  ),
                ),
                slider(
                  title: l10n.parallelDownloads,
                  subtitle: l10n.parallelDownloadsSubtitle,
                  value: parallel,
                  min: DownloadPrefs.parallelMin,
                  max: DownloadPrefs.parallelMax,
                  onChanged: (n) => parallel = n,
                  // On release: persist + apply live to both paths (MP4 queue +
                  // HLS service). Raising it starts queued episodes immediately;
                  // lowering it just stops new ones spawning.
                  onCommit: (n) {
                    prefs.setParallelDownloads(n);
                    sl<DownloadManager>().setParallel(n);
                  },
                ),
                const SizedBox(height: 8),
                slider(
                  title: l10n.connectionsPerDownload,
                  subtitle: l10n.connectionsPerDownloadSubtitle,
                  value: connections,
                  min: DownloadPrefs.connectionsMin,
                  max: DownloadPrefs.connectionsMax,
                  onChanged: (n) => connections = n,
                  onCommit: (n) => prefs.setConnectionsPerDownload(n),
                ),
                const SizedBox(height: 12),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const DownloadsScreenTv();
    final manager = sl<DownloadManager>();
    final store = sl<ChapterDownloadStore>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        showBack: widget.showBack,
        context.l10n.downloads,
        actions: [
          IconButton(
            tooltip: context.l10n.downloadSettings,
            icon: const Icon(Icons.tune_rounded),
            onPressed: _openDownloadSettings,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final groups = manager.byShow;
          return Column(
            children: [
              _locationHeader(),
              _chapterLinks(store),
              if (groups.isEmpty)
                Expanded(
                  child: EmptyState(
                    icon: Icons.download_outlined,
                    message: context.l10n.episodesYouDownloadAppearHere,
                  ),
                )
              else ...[
                _searchField(),
                Expanded(child: _list(groups, manager)),
              ],
            ],
          );
        },
      ),
    );
  }

  /// Manga and novel downloads get their own screens — they're chapters, not
  /// episodes, and listing them here made this screen a dumping ground. These
  /// two rows are just the way in, with a count so you can see there's
  /// something there without opening it.
  ///
  /// Only these rows watch the chapter box. It's written twice a second while
  /// a chapter downloads, and the video list below has no reason to rebuild
  /// for that.
  Widget _chapterLinks(ChapterDownloadStore store) {
    return ValueListenableBuilder<Box<Map>>(
      valueListenable: store.listenable(),
      builder: (context, box, _) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: Row(
          children: [
            for (final m in const [ContentMode.manga, ContentMode.novel]) ...[
              Expanded(child: _chapterCard(m, store.countDone(m))),
              if (m == ContentMode.manga) const SizedBox(width: 10),
            ],
          ],
        ),
      ),
    );
  }

  /// Side by side rather than two full-width rows: they're a way into the other
  /// two screens, not content, and stacked they pushed the episode list most of
  /// a screen down.
  Widget _chapterCard(ContentMode mode, int count) {
    final novel = mode == ContentMode.novel;
    final l10n = context.l10n;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChapterDownloadsScreen(mode: mode),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 11, 10, 11),
          child: Row(
            children: [
              Icon(chapterIcon(mode), color: AppColors.accent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      novel ? l10n.novels : l10n.modeManga,
                      style: AppText.body.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      l10n.chapterCount(count),
                      style: AppText.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: AppColors.textTertiary,
                size: 20,
              ),
            ],
          ),
        ),
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
      return EmptyState(
        icon: Icons.search_off_rounded,
        message: context.l10n.noDownloadsMatchYourSearch,
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
            context.l10n.downloadedSummary(count, fmtDownloadSize(bytes)),
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
              anyExpanded ? context.l10n.collapseAll : context.l10n.expandAll,
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
    final l10n = context.l10n;
    final head = records.first;
    final doneRecs =
        records.where((r) => r.status == DownloadStatus.done).toList();
    final groupBytes = doneRecs.fold<int>(0, (s, r) => s + r.bytesTotal);
    final sizeSuffix = groupBytes > 0 ? ' · ${fmtDownloadSize(groupBytes)}' : '';
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
                        l10n.ofTotalDownloaded(doneRecs.length, records.length) +
                            sizeSuffix,
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
                  tooltip: l10n.deleteAllEpisodesTooltip,
                  onPressed: () => _confirmDeleteAll(context),
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

  /// Confirm, then wipe every episode of this show in one go.
  Future<void> _confirmDeleteAll(BuildContext context) async {
    final l10n = context.l10n;
    final n = records.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.deleteAllDownloads, style: AppText.headline),
        content: Text(
          l10n.removeAllEpisodesOfShow(n, records.first.showTitle),
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
    if (ok == true) await manager.deleteAll(records);
  }
}

/// Launches playback of a completed [DownloadRecord].
/// Called by both [DownloadTile] (phone touch path) and [DownloadsScreenTv]
/// (TV D-pad OK path) so the play logic lives in one place.
///
/// Phone plays through [PlayerScreen] (media_kit); TV routes to the same two
/// ExoPlayer paths streaming already uses, so nothing on TV touches media_kit.
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
  // The file is already on disk, so "resolving" is just handing back a source
  // pointing at it — same shape both players expect from a network resolve.
  Future<List<VideoSource>> resolveSources(String _) async => [
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
  ];
  final scrobbleTitle = record.malId != null ? record.showTitle : null;

  if (sl<AppMode>().isTv) {
    await launchTvPlayback(
      context: context,
      sourceId: record.sourceId,
      episodes: [ep],
      startIndex: 0,
      resume: sl<ResumeStore>(),
      resolveSources: resolveSources,
      showUrl: record.showUrl,
      showTitle: record.showTitle,
      cover: record.cover,
      coverHeaders: record.coverHeaders,
      category: record.category,
      malId: record.malId,
      scrobbleTitle: scrobbleTitle,
    );
    return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PlayerScreen(
        sourceId: record.sourceId,
        episodes: [ep],
        startIndex: 0,
        resume: sl<ResumeStore>(),
        resolveSources: resolveSources,
        history: sl<WatchHistory>(),
        showTitle: record.showTitle,
        cover: record.cover,
        coverHeaders: record.coverHeaders,
        showUrl: record.showUrl,
        category: record.category,
        malId: record.malId,
        scrobbleTitle: scrobbleTitle,
      ),
    ),
  );
}

class DownloadTile extends StatelessWidget {
  const DownloadTile({super.key, required this.record, required this.manager});
  final DownloadRecord record;
  final DownloadManager manager;

  String _epLabel(AppLocalizations l10n) {
    final n = record.episodeNumber?.toInt();
    final t = record.episodeTitle.trim();
    if (n != null) {
      final short = l10n.episodeNumberShort(n);
      if (t.isEmpty || t == short || t == l10n.episodeLabel(n)) return short;
      return l10n.episodeWithTitleDot(n, t);
    }
    final generic =
        l10n.episodeSemantic(1).replaceFirst(' 1', '').replaceFirst('1', '');
    return (t.isEmpty || t == generic) ? generic : '$generic · $t';
  }

  String _subtitle(AppLocalizations l10n) {
    // A finished torrent is streamed into the user's folder — surface that phase.
    if (record.isTorrent &&
        manager.torrentProgress[record.id]?.status == 'copying') {
      return l10n.savingToYourFolder;
    }
    final pct = (record.progress * 100).round();
    return switch (record.status) {
      DownloadStatus.done => record.bytesTotal > 0
          ? fmtDownloadSize(record.bytesTotal)
          : l10n.downloaded,
      DownloadStatus.downloading => record.bytesTotal > 0
          ? l10n.downloadProgressPercentOfSize(
              pct,
              fmtDownloadSize(record.bytesTotal),
            ) + _torrentSuffix(l10n)
          : l10n.downloadProgressPercent(pct) + _torrentSuffix(l10n),
      DownloadStatus.paused => l10n.downloadPausedProgress(pct),
      DownloadStatus.queued => l10n.downloadQueued,
      DownloadStatus.resolving => l10n.downloadPreparing,
      DownloadStatus.unsupported =>
        record.error ?? l10n.notAvailableOfflineYet,
      DownloadStatus.failed => record.error ?? l10n.downloadFailedStatus,
      DownloadStatus.canceled => l10n.downloadCanceled,
    };
  }

  /// " · N peers · X MB/s" for an active torrent download (empty otherwise).
  String _torrentSuffix(AppLocalizations l10n) {
    if (!record.isTorrent) return '';
    final TorrentDownloadProgress? p = manager.torrentProgress[record.id];
    if (p == null) return '';
    final parts = <String>[];
    if (p.peers > 0) parts.add(l10n.peerCount(p.peers));
    if (p.downSpeedBps > 0) {
      final mb = p.downSpeedBps / (1024 * 1024);
      parts.add(mb >= 1
          ? l10n.downloadSpeedMbps(mb.toStringAsFixed(1))
          : l10n.downloadSpeedKbps((p.downSpeedBps / 1024).round()));
    }
    return parts.isEmpty ? '' : ' · ${parts.join(' · ')}';
  }

  Future<void> _play(BuildContext context) =>
      launchDownloadedEpisode(context, record);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isDone = record.status == DownloadStatus.done;
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      onTap: isDone ? () => _play(context) : null,
      leading: _StatusGlyph(record: record),
      title: Text(
        _epLabel(l10n),
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_subtitle(l10n), style: AppText.caption),
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
      DownloadStatus.done => Icon(
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
      DownloadStatus.failed => Icon(
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
    final l10n = context.l10n;
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
          case 'retry':
            unawaited(manager.retry(r));
          // Cancel an in-flight download = stop it AND remove it from the list
          // (delete cancels the task, drops the record, and clears fallbacks).
          case 'cancel':
          case 'delete':
            unawaited(manager.delete(r));
        }
      },
      itemBuilder: (context) => [
        if (r.status == DownloadStatus.downloading)
          _item('pause', Icons.pause_rounded, l10n.pause),
        if (r.status == DownloadStatus.paused)
          _item('resume', Icons.play_arrow_rounded, l10n.resume),
        if (r.status == DownloadStatus.failed && !r.isTorrent)
          _item('retry', Icons.refresh_rounded, l10n.retry),
        if (r.isActive) _item('cancel', Icons.close_rounded, l10n.cancel),
        _item('delete', Icons.delete_outline_rounded, l10n.delete),
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
