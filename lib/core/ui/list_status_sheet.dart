import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import '../models/media_item.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import '../playback/list_status_store.dart';
import '../playback/my_list.dart';
import '../repository/source_repository.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../tracker/tracker.dart';
import '../tracker/tracker_hub.dart';
import '../tv/tv_focusable.dart';

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

  // Single source of truth for "is this a reading title" — derived from the
  // ITEM, not the global content mode. The label (below) and the tracker
  // kind (in _syncToTrackers) both read this same value, so they can never
  // disagree with each other again.
  final reading =
      item.type == ProviderType.manga || item.type == ProviderType.novel;

  final picked = await showModalBottomSheet<Object?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) =>
        ListStatusSheet(current: current, inList: inList, reading: reading),
  );
  if (picked == null) return;

  final isAnime = item.type == ProviderType.anime;

  if (picked == _kRemove) {
    await myList.remove(item);
    await statusStore.remove(item);
    onChanged?.call();
    _syncToTrackers(item, null, malId, tmdbId, tmdbIsTv, imdbId, isAnime,
        reading: reading, remove: true);
    return;
  }

  final status = picked as WatchStatus;
  await myList.add(item);
  await statusStore.setStatus(item, status);
  await myList.pushStatus(item); // sync the watch status to the cloud row
  onChanged?.call();
  _syncToTrackers(item, status, malId, tmdbId, tmdbIsTv, imdbId, isAnime,
      reading: reading);
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
  required bool reading,
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
  // Manga/novel sources (Mihon) don't carry a malId, so — exactly like anime —
  // fall back to a title search on the tracker. Without this, reading titles
  // never reached the tracker (all ids null + no title = nothing to match).
  // Movies/TV stay null: they resolve by tmdbId/imdbId, not a title search.
  final title = (isAnime || reading) ? item.title : null;
  final kind = reading ? MediaKind.manga : MediaKind.anime;
  if (remove) {
    await hub.removeFromList(
      malId: mal,
      title: title,
      tmdbId: tmdb,
      tmdbIsTv: isTv,
      imdbId: imdb,
      kind: kind,
    );
  } else if (status != null) {
    await hub.setStatus(
      malId: mal,
      title: title,
      tmdbId: tmdb,
      tmdbIsTv: isTv,
      imdbId: imdb,
      status: status,
      kind: kind,
    );
  }
}

/// "Add to your list" status picker. Pops a [WatchStatus], the remove sentinel,
/// or null on dismiss.
class ListStatusSheet extends StatelessWidget {
  const ListStatusSheet({
    super.key,
    required this.current,
    required this.inList,
    required this.reading,
  });

  final WatchStatus? current;
  final bool inList;

  /// Whether [current]'s owning item is manga/novel — derived by the caller
  /// from `item.type` (NOT the global content mode: this sheet is reachable
  /// from My List / History rows whose type can differ from whatever mode
  /// the user happens to be browsing in). Drives the Watching/Reading and
  /// Plan to Watch/Read labels below.
  final bool reading;

  @override
  Widget build(BuildContext context) {
    final statuses = WatchStatus.values;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
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
              for (var i = 0; i < statuses.length; i++)
                _row(
                  autofocus: i == 0,
                  onTap: () => Navigator.pop(context, statuses[i]),
                  child: ListTile(
                    leading: Icon(
                      _iconFor(statuses[i]),
                      color: current == statuses[i]
                          ? AppColors.accent
                          : AppColors.textSecondary,
                    ),
                    title: Text(
                      labelFor(statuses[i], reading: reading),
                      style: AppText.body.copyWith(
                        color: current == statuses[i]
                            ? AppColors.accent
                            : AppColors.textPrimary,
                        fontWeight: current == statuses[i]
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    trailing: current == statuses[i]
                        ? Icon(Icons.check_rounded, color: AppColors.accent)
                        : null,
                    onTap: () => Navigator.pop(context, statuses[i]),
                  ),
                ),
              if (inList) ...[
                const Divider(height: 1, color: AppColors.hairline),
                _row(
                  onTap: () => Navigator.pop(context, _kRemove),
                  child: ListTile(
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
                ),
              ],
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Phone keeps the ListTile as-is. TV wraps it so D-pad OK can pick a status
  /// after a held-OK on a My List poster (ListTile alone has no TV key path).
  Widget _row({
    required Widget child,
    required VoidCallback onTap,
    bool autofocus = false,
  }) {
    if (!sl.isRegistered<AppMode>() || !sl<AppMode>().isTv) return child;
    return TvFocusable(
      scale: 1.0,
      autofocus: autofocus,
      onTap: onTap,
      child: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: false,
        child: child,
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
