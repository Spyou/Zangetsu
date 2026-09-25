import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/zmode/metadata_filters.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../l10n/l10n.dart';

/// Leanback filter dialog for TV Search.
///
/// The phone sheet (`showMetaFilterSheet`) uses [InkWell] cells and a nested
/// [GestureDetector] genre wrap — on a remote the only Material focusable is
/// **Done**, which is the [#116](https://github.com/Spyou/Zangetsu/issues/116)
/// report. This dialog is full-size at 10 feet, every row is a [TvListFocusable],
/// and the genre picker autofocuses the first genre (not Done).
Future<MetaFilters?> showMetaFilterDialogTv(
  BuildContext context,
  ZKind kind,
  MetaFilters current,
) {
  return showDialog<MetaFilters>(
    context: context,
    useRootNavigator: true,
    requestFocus: true,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    builder: (_) => _MetaFilterDialogTv(kind: kind, initial: current),
  );
}

class _MetaFilterDialogTv extends StatefulWidget {
  const _MetaFilterDialogTv({required this.kind, required this.initial});

  final ZKind kind;
  final MetaFilters initial;

  @override
  State<_MetaFilterDialogTv> createState() => _MetaFilterDialogTvState();
}

class _MetaFilterDialogTvState extends State<_MetaFilterDialogTv> {
  late MetaFilters _f = widget.initial;

  bool get _isVideo => widget.kind == ZKind.movie || widget.kind == ZKind.tv;

  /// Sort is excluded unless moved off its default — every search is sorted,
  /// so counting it would say "1 filter" on an untouched dialog.
  int get _count =>
      (_f.genres.isNotEmpty ? 1 : 0) +
      (_f.year != null ? 1 : 0) +
      (_f.season != null ? 1 : 0) +
      (_f.format != null ? 1 : 0) +
      (_f.status != null ? 1 : 0) +
      (_f.minScore != null ? 1 : 0) +
      (_f.sort != MetaSort.popularity ? 1 : 0);

  List<MetaFormat> get _formats {
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final height = MediaQuery.sizeOf(context).height;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 56, vertical: 16),
      child: FocusScope(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 640,
            maxWidth: 760,
            maxHeight: height * 0.88,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.filters,
                        style: AppText.largeTitle.copyWith(fontSize: 26),
                      ),
                    ),
                    if (_count > 0)
                      TvFocusable(
                        key: const ValueKey('tv-meta-filter-reset'),
                        variant: TvFocusVariant.pill,
                        scale: 1.0,
                        semanticLabel: l10n.reset,
                        onTap: () =>
                            setState(() => _f = MetaFilters(adult: _f.adult)),
                        builder: (focused) => Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          child: Text(
                            l10n.reset,
                            style: AppText.headline.copyWith(
                              fontSize: 17,
                              color: focused ? Colors.black : AppColors.accent,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('tv-meta-filter-dialog'),
                    child: Column(
                      children: [
                        _row(
                          key: const ValueKey('tv-meta-filter-sort'),
                          title: l10n.sortBy,
                          value: metaSortLabel(context, _f.sort),
                          on: _f.sort != MetaSort.popularity,
                          autofocus: true,
                          onTap: () => _pick<MetaSort>(
                            title: l10n.sortBy,
                            values: MetaSort.values,
                            current: _f.sort,
                            label: (v) => metaSortLabel(context, v),
                            allowClear: false,
                            onPicked: (v) =>
                                setState(() => _f = _f.copyWith(sort: v)),
                          ),
                        ),
                        _row(
                          key: const ValueKey('tv-meta-filter-genres'),
                          title: l10n.genres,
                          value: _f.genres.isEmpty
                              ? l10n.any
                              : _f.genres.join(', '),
                          on: _f.genres.isNotEmpty,
                          onTap: _pickGenres,
                        ),
                        _row(
                          key: const ValueKey('tv-meta-filter-year'),
                          title: l10n.year,
                          value: _f.year?.toString() ?? l10n.any,
                          on: _f.year != null,
                          onTap: () => _pick<int>(
                            title: l10n.year,
                            values: [
                              for (
                                var y = DateTime.now().year;
                                y > DateTime.now().year - 25;
                                y--
                              )
                                y,
                            ],
                            current: _f.year,
                            label: (y) => '$y',
                            onPicked: (v) => setState(
                              () => _f = v == null
                                  ? _f.copyWith(clearYear: true)
                                  : _f.copyWith(year: v),
                            ),
                          ),
                        ),
                        _row(
                          key: const ValueKey('tv-meta-filter-status'),
                          title: l10n.status,
                          value: _f.status == null
                              ? l10n.any
                              : metaStatusLabel(_f.status!),
                          on: _f.status != null,
                          onTap: () => _pick<MetaStatus>(
                            title: l10n.status,
                            values: MetaStatus.values,
                            current: _f.status,
                            label: metaStatusLabel,
                            onPicked: (v) => setState(
                              () => _f = v == null
                                  ? _f.copyWith(clearStatus: true)
                                  : _f.copyWith(status: v),
                            ),
                          ),
                        ),
                        _row(
                          key: const ValueKey('tv-meta-filter-score'),
                          title: l10n.minimumScore,
                          value: _f.minScore == null
                              ? l10n.any
                              : '${_f.minScore}+',
                          on: _f.minScore != null,
                          onTap: () => _pick<int>(
                            title: l10n.minimumScore,
                            values: const [50, 60, 70, 80, 90],
                            current: _f.minScore,
                            label: (v) => '$v+',
                            onPicked: (v) => setState(
                              () => _f = v == null
                                  ? _f.copyWith(clearScore: true)
                                  : _f.copyWith(minScore: v),
                            ),
                          ),
                        ),
                        if (!_isVideo)
                          _row(
                            key: const ValueKey('tv-meta-filter-season'),
                            title: l10n.season,
                            value: _f.season == null
                                ? l10n.any
                                : metaSeasonLabel(_f.season!),
                            on: _f.season != null,
                            onTap: () => _pick<MetaSeason>(
                              title: l10n.season,
                              values: MetaSeason.values,
                              current: _f.season,
                              label: metaSeasonLabel,
                              onPicked: (v) => setState(
                                () => _f = v == null
                                    ? _f.copyWith(clearSeason: true)
                                    : _f.copyWith(season: v),
                              ),
                            ),
                          ),
                        if (_formats.isNotEmpty)
                          _row(
                            key: const ValueKey('tv-meta-filter-format'),
                            title: l10n.format,
                            value: _f.format == null
                                ? l10n.any
                                : metaFormatLabel(_f.format!),
                            on: _f.format != null,
                            onTap: () => _pick<MetaFormat>(
                              title: l10n.format,
                              values: _formats,
                              current: _f.format,
                              label: metaFormatLabel,
                              onPicked: (v) => setState(
                                () => _f = v == null
                                    ? _f.copyWith(clearFormat: true)
                                    : _f.copyWith(format: v),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TvFocusable(
                  key: const ValueKey('tv-meta-filter-apply'),
                  variant: TvFocusVariant.none,
                  semanticLabel: l10n.apply,
                  onTap: () => Navigator.of(context).pop(_f),
                  builder: (focused) => DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: focused ? Colors.white : Colors.transparent,
                        width: 2.5,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text(
                          _count == 0 ? l10n.apply : '${l10n.apply} ($_count)',
                          style: AppText.headline.copyWith(
                            fontSize: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row({
    required Key key,
    required String title,
    required String value,
    required bool on,
    required VoidCallback onTap,
    bool autofocus = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TvListFocusable(
        key: key,
        autofocus: autofocus,
        waitForKeyUp: true,
        semanticLabel: '$title, $value',
        onTap: onTap,
        builder: (focused) => Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: on
                  ? AppColors.accent.withValues(alpha: 0.7)
                  : Colors.transparent,
              width: 2,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: AppText.overline.copyWith(
                        fontSize: 12,
                        letterSpacing: 1,
                        color: focused
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.headline.copyWith(
                        fontSize: 18,
                        color: on ? AppColors.accent : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 28,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pick<T>({
    required String title,
    required List<T> values,
    required T? current,
    required String Function(T) label,
    required void Function(T? value) onPicked,
    bool allowClear = true,
  }) async {
    final picked = await showDialog<Object>(
      context: context,
      useRootNavigator: true,
      requestFocus: true,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      builder: (ctx) {
        final l10n = ctx.l10n;
        final items = <(Object?, String, bool)>[
          if (allowClear) (null, l10n.any, current == null),
          for (final v in values) (v, label(v), v == current),
        ];
        var autofocusIdx = items.indexWhere((e) => e.$3);
        if (autofocusIdx < 0) autofocusIdx = 0;
        return _TvPickerScaffold(
          title: title,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: items.length,
            itemBuilder: (_, i) {
              final (value, text, selected) = items[i];
              return TvListFocusable(
                autofocus: i == autofocusIdx,
                semanticLabel: text,
                onTap: () =>
                    Navigator.of(ctx).pop(value ?? _TvPickerClear.instance),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          text,
                          style: AppText.headline.copyWith(fontSize: 18),
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.check_rounded,
                          color: AppColors.accent,
                          size: 24,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
    if (!mounted || picked == null) return;
    if (identical(picked, _TvPickerClear.instance)) {
      onPicked(null);
      return;
    }
    onPicked(picked as T);
  }

  Future<void> _pickGenres() async {
    final picked = await showDialog<List<String>>(
      context: context,
      useRootNavigator: true,
      requestFocus: true,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      builder: (ctx) => _TvGenrePicker(
        kind: widget.kind,
        adult: _f.adult,
        selected: _f.genres,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _f = _f.copyWith(genres: picked));
  }
}

/// Sentinel so a null "Any" pick is distinct from dismissing the dialog.
class _TvPickerClear {
  const _TvPickerClear._();
  static const instance = _TvPickerClear._();
}

class _TvPickerScaffold extends StatelessWidget {
  const _TvPickerScaffold({
    required this.title,
    required this.child,
    this.footer,
  });

  final String title;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 96, vertical: 36),
      child: FocusScope(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 520,
            maxWidth: 640,
            maxHeight: height * 0.82,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 24, 8, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                  child: Text(
                    title,
                    style: AppText.largeTitle.copyWith(fontSize: 24),
                  ),
                ),
                Flexible(child: child),
                ?footer,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Multi-select genre picker. First genre is autofocused so D-pad does not
/// land on Done the way the phone [GestureDetector] wrap did.
class _TvGenrePicker extends StatefulWidget {
  const _TvGenrePicker({
    required this.kind,
    required this.adult,
    required this.selected,
  });

  final ZKind kind;
  final bool adult;
  final List<String> selected;

  @override
  State<_TvGenrePicker> createState() => _TvGenrePickerState();
}

class _TvGenrePickerState extends State<_TvGenrePicker> {
  late final List<String> _sel = [...widget.selected];

  @override
  Widget build(BuildContext context) {
    final genres = metaGenresFor(widget.kind, adult: widget.adult);
    final l10n = context.l10n;
    return _TvPickerScaffold(
      title: l10n.genres,
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: TvFocusable(
          key: const ValueKey('tv-genre-done'),
          variant: TvFocusVariant.none,
          semanticLabel: l10n.done,
          onTap: () => Navigator.of(context).pop(List<String>.from(_sel)),
          builder: (focused) => DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: focused ? Colors.white : Colors.transparent,
                width: 2.5,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text(
                  l10n.done,
                  style: AppText.headline.copyWith(
                    fontSize: 18,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child: SingleChildScrollView(
        key: const ValueKey('tv-genre-picker'),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          children: [
            for (var i = 0; i < genres.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
                child: TvListFocusable(
                  key: ValueKey('tv-genre-${genres[i]}'),
                  autofocus: i == 0,
                  semanticLabel: genres[i],
                  onTap: () => setState(() {
                    _sel.contains(genres[i])
                        ? _sel.remove(genres[i])
                        : _sel.add(genres[i]);
                  }),
                  builder: (_) {
                    final g = genres[i];
                    final on = _sel.contains(g);
                    return Container(
                      constraints: const BoxConstraints(minHeight: 56),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: on
                            ? AppColors.accent.withValues(alpha: 0.16)
                            : AppColors.surface2,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: on ? AppColors.accent : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            on
                                ? Icons.check_box_rounded
                                : Icons.check_box_outline_blank_rounded,
                            color: on
                                ? AppColors.accent
                                : AppColors.textSecondary,
                            size: 26,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              g,
                              style: AppText.headline.copyWith(
                                fontSize: 18,
                                color: on
                                    ? AppColors.accent
                                    : AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
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

String metaSortLabel(BuildContext c, MetaSort s) => switch (s) {
  MetaSort.popularity => c.l10n.sortPopularity,
  MetaSort.score => c.l10n.sortScore,
  MetaSort.trending => c.l10n.sortTrending,
  MetaSort.newest => c.l10n.sortNewest,
  MetaSort.title => c.l10n.sortTitle,
};

String metaSeasonLabel(MetaSeason s) => switch (s) {
  MetaSeason.winter => 'Winter',
  MetaSeason.spring => 'Spring',
  MetaSeason.summer => 'Summer',
  MetaSeason.fall => 'Fall',
};

String metaFormatLabel(MetaFormat f) => switch (f) {
  MetaFormat.tv => 'TV',
  MetaFormat.movie => 'Movie',
  MetaFormat.ova => 'OVA',
  MetaFormat.special => 'Special',
  MetaFormat.manga => 'Manga',
  MetaFormat.novel => 'Novel',
  MetaFormat.oneShot => 'One shot',
};

String metaStatusLabel(MetaStatus s) => switch (s) {
  MetaStatus.releasing => 'Airing',
  MetaStatus.finished => 'Finished',
  MetaStatus.notYetReleased => 'Upcoming',
  MetaStatus.cancelled => 'Cancelled',
};
