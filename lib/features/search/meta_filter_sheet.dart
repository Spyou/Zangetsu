import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/zmode/metadata_filters.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../l10n/l10n.dart';

/// Filter sheet for the metadata catalogue.
///
/// A half-height list rather than a full-height wall of chips: seven filters
/// as chips ran past two screens, so nothing below Genres was ever seen. Each
/// row shows its current value and opens a small picker, which keeps the whole
/// set visible at once and leaves the results behind it in view.
///
/// Adult content is deliberately NOT here — it is a privacy setting, not a
/// search refinement, and lives in Settings → Privacy.
Future<MetaFilters?> showMetaFilterSheet(
  BuildContext context,
  ZKind kind,
  MetaFilters current,
) => showModalBottomSheet<MetaFilters>(
  context: context,
  backgroundColor: Colors.transparent,
  isScrollControlled: true,
  builder: (_) => _MetaFilterSheet(kind: kind, initial: current),
);

class _MetaFilterSheet extends StatefulWidget {
  const _MetaFilterSheet({required this.kind, required this.initial});

  final ZKind kind;
  final MetaFilters initial;

  @override
  State<_MetaFilterSheet> createState() => _MetaFilterSheetState();
}

class _MetaFilterSheetState extends State<_MetaFilterSheet> {
  late MetaFilters _f = widget.initial;

  bool get _isVideo => widget.kind == ZKind.movie || widget.kind == ZKind.tv;

  /// Sort is excluded unless moved off its default: every search is sorted, so
  /// counting it would say "1 filter" on an untouched sheet.
  int get _count =>
      (_f.genres.isNotEmpty ? 1 : 0) +
      (_f.year != null ? 1 : 0) +
      (_f.season != null ? 1 : 0) +
      (_f.format != null ? 1 : 0) +
      (_f.status != null ? 1 : 0) +
      (_f.minScore != null ? 1 : 0) +
      (_f.sort != MetaSort.popularity ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.32,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scroll) => DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.defaultBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.surface2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
              child: Row(
                children: [
                  Expanded(child: Text(l10n.filters, style: AppText.barTitle)),
                  // Only when there IS something to reset — a permanently
                  // visible one reads as an action you forgot to take.
                  if (_count > 0)
                    TextButton(
                      onPressed: () => setState(() => _f = const MetaFilters()),
                      child: Text(l10n.reset),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                children: [
                  // Two per row: these are short label/value pairs, and one
                  // per line pushed half of them below the fold of a half
                  // sheet — the thing the list format was meant to fix.
                  _pair(
                    _cell(
                      l10n.sortBy,
                      _sortLabel(context, _f.sort),
                      true,
                      () => _pick<MetaSort>(
                        l10n.sortBy,
                        MetaSort.values,
                        _f.sort,
                        (v) => _sortLabel(context, v),
                        (v) => setState(() => _f = _f.copyWith(sort: v)),
                      ),
                    ),
                    _cell(
                      l10n.year,
                      _f.year?.toString() ?? l10n.any,
                      _f.year != null,
                      () => _pick<int>(
                        l10n.year,
                        [
                          for (
                            var y = DateTime.now().year;
                            y > DateTime.now().year - 25;
                            y--
                          )
                            y,
                        ],
                        _f.year,
                        (y) => '$y',
                        (v) => setState(
                          () => _f = _f.year == v
                              ? _f.copyWith(clearYear: true)
                              : _f.copyWith(year: v),
                        ),
                      ),
                    ),
                  ),
                  _pair(
                    _cell(
                      l10n.status,
                      _f.status == null ? l10n.any : _statusLabel(_f.status!),
                      _f.status != null,
                      () => _pick<MetaStatus>(
                        l10n.status,
                        MetaStatus.values,
                        _f.status,
                        _statusLabel,
                        (v) => setState(
                          () => _f = _f.status == v
                              ? _f.copyWith(clearStatus: true)
                              : _f.copyWith(status: v),
                        ),
                      ),
                    ),
                    _cell(
                      l10n.minimumScore,
                      _f.minScore == null ? l10n.any : '${_f.minScore}+',
                      _f.minScore != null,
                      () => _pick<int>(
                        l10n.minimumScore,
                        const [50, 60, 70, 80, 90],
                        _f.minScore,
                        (v) => '$v+',
                        (v) => setState(
                          () => _f = _f.minScore == v
                              ? _f.copyWith(clearScore: true)
                              : _f.copyWith(minScore: v),
                        ),
                      ),
                    ),
                  ),
                  // Season is an anime idea; TMDB has no equivalent, so it
                  // would be a control that silently does nothing there.
                  _pair(
                    !_isVideo
                        ? _cell(
                            l10n.season,
                            _f.season == null
                                ? l10n.any
                                : _seasonLabel(_f.season!),
                            _f.season != null,
                            () => _pick<MetaSeason>(
                              l10n.season,
                              MetaSeason.values,
                              _f.season,
                              _seasonLabel,
                              (v) => setState(
                                () => _f = _f.season == v
                                    ? _f.copyWith(clearSeason: true)
                                    : _f.copyWith(season: v),
                              ),
                            ),
                          )
                        : null,
                    _formats().isEmpty
                        ? null
                        : _cell(
                            l10n.format,
                            _f.format == null
                                ? l10n.any
                                : _formatLabel(_f.format!),
                            _f.format != null,
                            () => _pick<MetaFormat>(
                              l10n.format,
                              _formats(),
                              _f.format,
                              _formatLabel,
                              (v) => setState(
                                () => _f = _f.format == v
                                    ? _f.copyWith(clearFormat: true)
                                    : _f.copyWith(format: v),
                              ),
                            ),
                          ),
                  ),
                  // Genres is the multi-select and its value is the longest,
                  // so it takes the full width rather than being truncated
                  // into half of one.
                  _cell(
                    l10n.genres,
                    _f.genres.isEmpty ? l10n.any : _f.genres.join(', '),
                    _f.genres.isNotEmpty,
                    _pickGenres,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(_f),
                  child: Text(
                    _count == 0 ? l10n.apply : '${l10n.apply} ($_count)',
                    style: AppText.button.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Two cells side by side. A null cell leaves its half empty rather than
  /// letting the other stretch, so the grid stays aligned when a filter does
  /// not apply to this kind.
  Widget _pair(Widget? a, Widget? b) {
    if (a == null && b == null) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: a ?? const SizedBox.shrink()),
        const SizedBox(width: 10),
        Expanded(child: b ?? const SizedBox.shrink()),
      ],
    );
  }

  /// One filter as a tappable box: label above, current value below. The value
  /// is the point — it makes the selection readable at a glance, which a grid
  /// of chips cannot do once there are seven filters.
  Widget _cell(String title, String value, bool on, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: on
                      ? AppColors.accent.withValues(alpha: 0.55)
                      : Colors.transparent,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title.toUpperCase(),
                    style: AppText.overline.copyWith(fontSize: 10),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body.copyWith(
                            fontSize: 14,
                            color: on
                                ? AppColors.accent
                                : AppColors.textPrimary,
                            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.expand_more_rounded,
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  /// Single-value picker. Tapping the current value clears it, so every filter
  /// can be undone without hunting for an "Any" entry.
  Future<void> _pick<T>(
    String title,
    List<T> values,
    T? current,
    String Function(T) label,
    void Function(T) onPicked,
  ) async {
    final v = await showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppColors.bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(title, style: AppText.barTitle),
            ),
            const SizedBox(height: 6),
            for (final v in values)
              ListTile(
                title: Text(label(v), style: AppText.body),
                trailing: v == current
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () => Navigator.of(sheet).pop(v),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (v == null || !mounted) return;
    onPicked(v);
  }

  /// Genres are the one multi-select, so they get chips of their own rather
  /// than a single-value list.
  Future<void> _pickGenres() async {
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      backgroundColor: AppColors.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheet) {
        var sel = [..._f.genres];
        return StatefulBuilder(
          builder: (sheet2, setSheet) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.genres, style: AppText.barTitle),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final g in metaGenresFor(widget.kind))
                        GestureDetector(
                          onTap: () => setSheet(() {
                            sel.contains(g) ? sel.remove(g) : sel.add(g);
                          }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: sel.contains(g)
                                  ? AppColors.accent.withValues(alpha: 0.16)
                                  : AppColors.surface,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: sel.contains(g)
                                    ? AppColors.accent
                                    : Colors.transparent,
                              ),
                            ),
                            child: Text(
                              g,
                              style: AppText.caption.copyWith(
                                color: sel.contains(g)
                                    ? AppColors.accent
                                    : AppColors.textPrimary,
                                fontWeight: sel.contains(g)
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.of(sheet2).pop(sel),
                      child: Text(
                        context.l10n.done,
                        style: AppText.button.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() => _f = _f.copyWith(genres: picked));
  }

  /// Formats worth offering. Manga and novel already pin their format by kind,
  /// so a picker there would contradict the query and return nothing.
  List<MetaFormat> _formats() {
    if (_isVideo) return const [MetaFormat.tv, MetaFormat.movie];
    if (widget.kind == ZKind.anime) {
      return const [
        MetaFormat.tv,
        MetaFormat.movie,
        MetaFormat.ova,
        MetaFormat.special,
      ];
    }
    return const [];
  }

  static String _sortLabel(BuildContext c, MetaSort s) => switch (s) {
    MetaSort.popularity => c.l10n.sortPopularity,
    MetaSort.score => c.l10n.sortScore,
    MetaSort.trending => c.l10n.sortTrending,
    MetaSort.newest => c.l10n.sortNewest,
    MetaSort.title => c.l10n.sortTitle,
  };

  static String _seasonLabel(MetaSeason s) => switch (s) {
    MetaSeason.winter => 'Winter',
    MetaSeason.spring => 'Spring',
    MetaSeason.summer => 'Summer',
    MetaSeason.fall => 'Fall',
  };

  static String _formatLabel(MetaFormat f) => switch (f) {
    MetaFormat.tv => 'TV',
    MetaFormat.movie => 'Movie',
    MetaFormat.ova => 'OVA',
    MetaFormat.special => 'Special',
    MetaFormat.manga => 'Manga',
    MetaFormat.novel => 'Novel',
    MetaFormat.oneShot => 'One shot',
  };

  static String _statusLabel(MetaStatus s) => switch (s) {
    MetaStatus.releasing => 'Airing',
    MetaStatus.finished => 'Finished',
    MetaStatus.notYetReleased => 'Upcoming',
    MetaStatus.cancelled => 'Cancelled',
  };
}
