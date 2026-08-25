import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import '../models/media_item.dart';
import '../anilist/anilist_service.dart';
import '../models/provider_info.dart';
import '../models/watch_status.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../tv/tv_focusable.dart';
import '../tv/tv_list_focusable.dart';
import 'anilist_custom_lists_sheet.dart';
import '../tracker/tracker.dart';

/// Per-card editor for ONE tracker's library entry (AniList / MAL). Unlike the
/// own-list sheet ([showListStatusSheet]) — which mirrors a change to every
/// connected tracker — this writes only to [tracker]: status, episodes watched,
/// and score, plus Remove. [onFind] drops into search to actually play the
/// title (tracker items carry no playable source); [onChanged] fires after a
/// write so the caller can refresh that tracker's list.
Future<void> showTrackerEntrySheet(
  BuildContext context, {
  required Tracker tracker,
  required MediaItem item,
  WatchStatus? status,
  int? progress,
  double? score,
  bool tmdbIsTv = false,
  VoidCallback? onFind,
  VoidCallback? onChanged,
  List<String> customLists = const [],
}) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _TrackerEntrySheet(
      tracker: tracker,
      customLists: customLists,
      item: item,
      status: status,
      progress: progress,
      score: score,
      tmdbIsTv: tmdbIsTv,
      onFind: onFind,
      onChanged: onChanged,
    ),
  );
}

class _TrackerEntrySheet extends StatefulWidget {
  const _TrackerEntrySheet({
    required this.tracker,
    required this.customLists,
    required this.item,
    required this.status,
    required this.progress,
    required this.score,
    required this.tmdbIsTv,
    required this.onFind,
    required this.onChanged,
  });

  final Tracker tracker;

  /// Which of the tracker's own custom lists this entry is in. AniList only —
  /// the row below doesn't appear for the others, which have no such concept.
  final List<String> customLists;
  final MediaItem item;
  final WatchStatus? status;
  final int? progress;
  final double? score;
  final bool tmdbIsTv;
  final VoidCallback? onFind;
  final VoidCallback? onChanged;

  @override
  State<_TrackerEntrySheet> createState() => _TrackerEntrySheetState();
}

class _TrackerEntrySheetState extends State<_TrackerEntrySheet> {
  /// Which tracker list this card lives on, taken from the item itself. Manga
  /// and novel entries (imported by `fetchList`) must write to the tracker's
  /// MANGA list — MAL/AniList reuse ids across their anime and manga id
  /// spaces, so an anime-kind write here would edit a completely unrelated
  /// show. Anime/movie items keep [MediaKind.anime], which is what every one
  /// of these calls already defaulted to.
  MediaKind get _kind => switch (widget.item.type) {
    ProviderType.manga || ProviderType.novel => MediaKind.manga,
    ProviderType.anime || ProviderType.movie => MediaKind.anime,
  };

  bool get _reading => _kind == MediaKind.manga;

  late WatchStatus? _status = widget.status;
  late int _progress = widget.progress ?? 0;
  late int _score = (widget.score ?? 0).round().clamp(0, 10);
  bool _busy = false;

  Future<void> _apply() async {
    if (_busy) return;
    // Only push the fields the user actually changed — leaving the rest null so
    // updateEntry doesn't re-write (and possibly clobber/round) an untouched
    // score or progress. If nothing changed, don't write at all.
    final statusChanged = _status != widget.status;
    final progressChanged = _progress != (widget.progress ?? 0);
    final scoreChanged =
        _score != (widget.score ?? 0).round().clamp(0, 10);
    if (!statusChanged && !progressChanged && !scoreChanged) {
      Navigator.pop(context);
      return;
    }
    setState(() => _busy = true);
    await widget.tracker.updateEntry(
      malId: widget.item.malId,
      tmdbId: widget.item.tmdbId,
      imdbId: widget.item.imdbId,
      title: widget.item.title,
      tmdbIsTv: widget.tmdbIsTv,
      status: statusChanged ? _status : null,
      score: scoreChanged ? _score.toDouble() : null,
      progress: progressChanged ? _progress : null,
      kind: _kind,
    );
    widget.onChanged?.call();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _remove() async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.tracker.removeFromList(
      malId: widget.item.malId,
      tmdbId: widget.item.tmdbId,
      imdbId: widget.item.imdbId,
      title: widget.item.title,
      tmdbIsTv: widget.tmdbIsTv,
      kind: _kind,
    );
    widget.onChanged?.call();
    if (mounted) Navigator.pop(context);
  }

  bool get _isTv =>
      sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  @override
  Widget build(BuildContext context) {
    // Cap height + scroll so status chips / steppers / actions don't overflow
    // the bottom sheet on TV (extra TvFocusable chrome) or short phone screens.
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.85,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                _header(),
                const Divider(
                    height: 1, thickness: 1, color: AppColors.hairline),
                const SizedBox(height: 18),
                _statusChips(),
                _customListsRow(context),
                const SizedBox(height: 20),
                _stepperRow(
                  _reading ? 'Chapters' : 'Episodes',
                  _progress.toString(),
                  onMinus: _progress > 0
                      ? () => setState(() => _progress--)
                      : null,
                  onPlus: () => setState(() => _progress++),
                ),
                const SizedBox(height: 16),
                _stepperRow(
                  'Score',
                  _score == 0 ? 'Not rated' : '$_score / 10',
                  onMinus:
                      _score > 0 ? () => setState(() => _score--) : null,
                  onPlus:
                      _score < 10 ? () => setState(() => _score++) : null,
                ),
                const SizedBox(height: 24),
                _applyButton(),
                const SizedBox(height: 6),
                if (widget.onFind != null)
                  _actionRow(
                    Icons.search_rounded,
                    'Find to watch',
                    color: AppColors.textPrimary,
                    onTap: _busy
                        ? null
                        : () {
                            Navigator.pop(context);
                            widget.onFind!.call();
                          },
                  ),
                _actionRow(
                  Icons.delete_outline_rounded,
                  'Remove from ${widget.tracker.displayName}',
                  color: AppColors.accent,
                  onTap: _busy ? null : _remove,
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionRow(IconData icon, String label,
      {required Color color, required VoidCallback? onTap}) {
    final row = InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 21, color: color),
            const SizedBox(width: 16),
            Text(label, style: AppText.body.copyWith(color: color)),
          ],
        ),
      ),
    );
    return _tvRow(
      onTap: onTap ?? () {},
      child: row,
    );
  }

  /// Phone keeps InkWell/ListTile as-is. TV wraps so D-pad OK can activate
  /// after a held-OK on a My List tracker poster.
  Widget _tvRow({
    required Widget child,
    required VoidCallback onTap,
    bool autofocus = false,
  }) {
    if (!_isTv) return child;
    return TvListFocusable(
      autofocus: autofocus,
      onTap: onTap,
      child: Focus(
        canRequestFocus: false,
        descendantsAreFocusable: false,
        child: child,
      ),
    );
  }

  Widget _header() {
    final cover = widget.item.cover;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 44,
              height: 62,
              child: cover == null || cover.isEmpty
                  ? ColoredBox(color: AppColors.surface2)
                  : CachedNetworkImage(
                      imageUrl: cover,
                      httpHeaders: widget.item.coverHeaders,
                      fit: BoxFit.cover,
                      placeholder: (_, _) =>
                          ColoredBox(color: AppColors.surface2),
                      errorWidget: (_, _, _) =>
                          ColoredBox(color: AppColors.surface2),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.headline),
                const SizedBox(height: 3),
                Text('on ${widget.tracker.displayName}',
                    style: AppText.caption
                        .copyWith(color: AppColors.textTertiary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Only AniList has user-defined lists. An `is` check rather than a method
  /// on the Tracker interface, which would make MAL and Simkl implement a
  /// permanent no-op.
  Widget _customListsRow(BuildContext context) {
    final service = widget.tracker;
    if (service is! AniListService) return const SizedBox.shrink();
    final n = widget.customLists.length;
    Future<void> openLists() async {
      // Grab the navigator's own context BEFORE popping. Using `context`
      // after the pop passes a dead one to the picker, whose first
      // `context.mounted` check then bails — the sheet closed and nothing
      // opened, which looked exactly like the row doing nothing.
      final rootContext = Navigator.of(context, rootNavigator: true).context;
      Navigator.pop(context);
      await showAniListCustomListsSheet(
        rootContext,
        service,
        widget.item,
        widget.customLists,
      );
      widget.onChanged?.call();
    }

    return _tvRow(
      onTap: openLists,
      child: ListTile(
        leading: const Icon(Icons.playlist_add_rounded,
            color: AppColors.textSecondary),
        title: const Text('Custom lists'),
        subtitle: Text(
          n == 0 ? 'Not in any' : widget.customLists.join(', '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption,
        ),
        trailing: const Icon(Icons.chevron_right_rounded,
            color: AppColors.textSecondary, size: 20),
        onTap: openLists,
      ),
    );
  }

  Widget _statusChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('STATUS',
              style: AppText.caption.copyWith(
                  color: AppColors.textTertiary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in WatchStatus.values) _statusChip(s),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusChip(WatchStatus s) {
    final selected = _status == s;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? AppColors.accent : AppColors.surface2,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        s.shortLabel,
        style: AppText.body.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: selected ? Colors.white : AppColors.textSecondary,
        ),
      ),
    );
    if (_isTv) {
      // Accent-selected chips need a white outline (float/box), not the
      // accent row wash — same rationale as [TvActionChip].
      return TvFocusable(
        variant: selected ? TvFocusVariant.float : TvFocusVariant.box,
        scale: 1.0,
        borderRadius: 18,
        onTap: () => setState(() => _status = s),
        child: chip,
      );
    }
    return GestureDetector(
      onTap: () => setState(() => _status = s),
      child: chip,
    );
  }

  Widget _stepperRow(String label, String value,
      {VoidCallback? onMinus, VoidCallback? onPlus}) {
    Widget btn(IconData icon, VoidCallback? onTap, String semantic) {
      final face = Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: AppColors.surface2,
          shape: BoxShape.circle,
        ),
        child: Icon(icon,
            size: 18,
            color: onTap == null ? AppColors.textTertiary : AppColors.accent),
      );
      if (!_isTv) {
        return GestureDetector(onTap: onTap, child: face);
      }
      if (onTap == null) return face;
      return TvFocusable(
        variant: TvFocusVariant.box,
        scale: 1.12,
        borderRadius: 17,
        semanticLabel: semantic,
        onTap: onTap,
        child: face,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Text(label,
              style: AppText.body.copyWith(color: AppColors.textPrimary)),
          const Spacer(),
          btn(Icons.remove_rounded, onMinus, 'Decrease $label'),
          SizedBox(
            width: 92,
            child: Text(value,
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700)),
          ),
          btn(Icons.add_rounded, onPlus, 'Increase $label'),
        ],
      ),
    );
  }

  Widget _applyButton() {
    // Plain accent face (not FilledButton) so TV focus chrome isn't fighting
    // Material's own focus node. Accent fill → white outline ([TvFocusVariant.box]),
    // never [TvListFocusable]/row — the red wash is invisible on a red button.
    final face = Container(
      width: double.infinity,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(14),
      ),
      child: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : Text('Apply changes',
              style: AppText.body.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w700)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: _isTv
          ? TvFocusable(
              autofocus: true,
              variant: TvFocusVariant.box,
              scale: 1.03,
              borderRadius: 14,
              semanticLabel: 'Apply changes',
              onTap: _busy ? () {} : _apply,
              child: face,
            )
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _busy ? null : _apply,
                borderRadius: BorderRadius.circular(14),
                child: face,
              ),
            ),
    );
  }
}
