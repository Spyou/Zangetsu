import 'package:flutter/material.dart';

import '../di/injector.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import '../playback/list_status_store.dart';
import '../playback/my_list.dart';
import '../repository/source_repository.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../tracker/tracker_hub.dart';

/// Sentinel popped by [ListStatusSheet] for the "Remove from list" row.
const String _kRemove = '__remove__';

/// Show the Add-to-List status picker for [item] and apply the choice
/// everywhere: My List membership, the local [WatchStatus], and a push to every
/// connected tracker. The local update is instant; tracker sync runs in the
/// background (resolving the MAL/TMDB id from the detail when the caller doesn't
/// already have it — e.g. a Home-banner card). [onChanged] fires after the
/// local update so the caller can rebuild its button.
Future<void> showListStatusSheet(
  BuildContext context, {
  required MediaItem item,
  int? malId,
  int? tmdbId,
  bool tmdbIsTv = false,
  String? imdbId,
  VoidCallback? onChanged,
}) async {
  final myList = sl<MyListStore>();
  final statusStore = sl<ListStatusStore>();
  final current = statusStore.statusOf(item);
  final inList = current != null || myList.contains(item);

  final picked = await showModalBottomSheet<Object?>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ListStatusSheet(current: current, inList: inList),
  );
  if (picked == null) return;

  final isAnime = item.type == ProviderType.anime;

  if (picked == _kRemove) {
    await myList.remove(item);
    await statusStore.remove(item);
    onChanged?.call();
    _syncToTrackers(item, null, malId, tmdbId, tmdbIsTv, imdbId, isAnime,
        remove: true);
    return;
  }

  final status = picked as WatchStatus;
  await myList.add(item);
  await statusStore.setStatus(item, status);
  onChanged?.call();
  _syncToTrackers(item, status, malId, tmdbId, tmdbIsTv, imdbId, isAnime);
}

/// Best-effort tracker push. Resolves the MAL/TMDB id from the detail when the
/// caller didn't supply one (browse cards don't carry ids). Fire-and-forget.
Future<void> _syncToTrackers(
  MediaItem item,
  WatchStatus? status,
  int? malId,
  int? tmdbId,
  bool tmdbIsTv,
  String? imdbId,
  bool isAnime, {
  bool remove = false,
}) async {
  final hub = sl<TrackerHub>();
  if (!hub.anyConnected) return;
  var mal = malId ?? item.malId;
  var tmdb = tmdbId ?? item.tmdbId;
  var imdb = imdbId ?? item.imdbId;
  var isTv = tmdbIsTv;
  if (mal == null && tmdb == null && (imdb == null || imdb.isEmpty)) {
    try {
      final d = await sl<SourceRepository>().detail(
        item.url,
        sourceId: item.sourceId,
      );
      mal = d.malId;
      tmdb = d.tmdbId;
      imdb = d.imdbId;
      isTv = d.tmdbIsTv;
    } catch (_) {/* leave ids null — title fallback still covers anime */}
  }
  final title = isAnime ? item.title : null;
  if (remove) {
    await hub.removeFromList(
      malId: mal,
      title: title,
      tmdbId: tmdb,
      tmdbIsTv: isTv,
      imdbId: imdb,
    );
  } else if (status != null) {
    await hub.setStatus(
      malId: mal,
      title: title,
      tmdbId: tmdb,
      tmdbIsTv: isTv,
      imdbId: imdb,
      status: status,
    );
  }
}

/// "Add to your list" status picker. Pops a [WatchStatus], the remove sentinel,
/// or null on dismiss.
class ListStatusSheet extends StatelessWidget {
  const ListStatusSheet({super.key, required this.current, required this.inList});

  final WatchStatus? current;
  final bool inList;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.hairline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Add to your list', style: AppText.headline),
            ),
          ),
          for (final s in WatchStatus.values)
            ListTile(
              leading: Icon(
                _iconFor(s),
                color: current == s ? AppColors.accent : AppColors.textSecondary,
              ),
              title: Text(
                s.label,
                style: AppText.body.copyWith(
                  color: current == s ? AppColors.accent : AppColors.textPrimary,
                  fontWeight: current == s ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              trailing: current == s
                  ? Icon(Icons.check_rounded, color: AppColors.accent)
                  : null,
              onTap: () => Navigator.pop(context, s),
            ),
          if (inList) ...[
            const Divider(height: 1, color: AppColors.hairline),
            ListTile(
              leading: Icon(
                Icons.delete_outline_rounded,
                color: AppColors.accent,
              ),
              title: Text(
                'Remove from list',
                style: AppText.body.copyWith(color: AppColors.accent),
              ),
              onTap: () => Navigator.pop(context, _kRemove),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  IconData _iconFor(WatchStatus s) => switch (s) {
    WatchStatus.planning => Icons.bookmark_add_outlined,
    WatchStatus.watching => Icons.play_circle_outline_rounded,
    WatchStatus.completed => Icons.check_circle_outline_rounded,
    WatchStatus.paused => Icons.pause_circle_outline_rounded,
    WatchStatus.dropped => Icons.cancel_outlined,
  };
}
