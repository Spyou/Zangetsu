// Episodes tab: list and grid rows, season sheet, range chips, jump dialog.
part of 'detail_screen.dart';


// ─────────────────────────────────────────────────────────────────────────────
// Episodes tab — season selector (multi-season) + rich episode rows. PRESERVES
// season filtering and _openPlayer. Sub/Dub selection now lives in the player.
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodesTab extends StatefulWidget {
  const _EpisodesTab({
    required this.eps,
    required this.seasonEps,
    required this.fillerEps,
    required this.hasMultipleSeasons,
    required this.seasonSet,
    required this.currentSeason,
    required this.onSelectSeason,
    required this.coverUrl,
    required this.coverHeaders,
    required this.sourceId,
    required this.showId,
    required this.showUrl,
    required this.resumeIndex,
    required this.hasAnyMark,
    this.trackerProgress,
    this.nextAiringEpisode,
    this.nextAiringAt,
    required this.onOpen,
    this.onPickPlayer,
    this.onRefresh,
    required this.onDownload,
    this.showDownload = true,
    this.isReading = false,
  });

  final List<Episode> eps;
  final List<Episode> seasonEps;
  final Set<int> fillerEps; // episode numbers that are filler
  final bool hasMultipleSeasons;
  final Set<int> seasonSet;
  final int currentSeason;
  final ValueChanged<int> onSelectSeason;
  final String coverUrl;
  final Map<String, String>? coverHeaders;
  final String sourceId;
  final String showId;
  final String showUrl;
  final int Function(List<Episode>) resumeIndex;
  final bool hasAnyMark;

  /// The connected tracker's watched-episode count, or null. Episodes at or
  /// below it render as watched (grey-out), merged with local playback marks.
  final int? trackerProgress;

  /// Next episode to air and when. Both null unless the title matched a
  /// tracker and is still airing, which is what keeps the row off finished
  /// shows and movies instead of showing an empty countdown.
  final int? nextAiringEpisode;
  final DateTime? nextAiringAt;
  final void Function(int fullIndex) onOpen;

  /// Long-press an episode → pick which player opens it, this once. Null on
  /// the reading path: a chapter opens the reader, so there's nothing to pick.
  final void Function(int fullIndex)? onPickPlayer;

  /// Force-refresh the list past the 10-min source cache (header ↻ button).
  /// Null hides the button.
  final Future<void> Function()? onRefresh;

  /// Per-episode download icon → opens the download sheet for that episode.
  final void Function(Episode ep) onDownload;

  /// False for reading types (manga/novel) — chapters resolve to a reader,
  /// not a video source, so the per-row download icon is hidden rather than
  /// left as a dead/misleading tap target.
  final bool showDownload;

  /// True for reading types — the section header reads "Chapters" instead
  /// of "Episodes" (single-season case only; multi-season keeps the season
  /// pill either way).
  final bool isReading;

  @override
  State<_EpisodesTab> createState() => _EpisodesTabState();
}

class _EpisodesTabState extends State<_EpisodesTab> {
  /// Long seasons are split into chunks of this size (CloudStream-style) so
  /// hundreds/thousands of episodes stay navigable via range chips.
  static const int _chunk = 50;

  bool _grid = false;
  int _rangeIndex = 0;
  String? _highlightEpId; // outlines a grid tile right after a jump

  @override
  void initState() {
    super.initState();
    _rangeIndex = _initialRange();
  }

  @override
  void didUpdateWidget(covariant _EpisodesTab old) {
    super.didUpdateWidget(old);
    // Season switched (or the episode set changed) → reset to the resume chunk.
    if (old.currentSeason != widget.currentSeason ||
        old.seasonEps.length != widget.seasonEps.length) {
      _rangeIndex = _initialRange();
      _highlightEpId = null;
    }
  }

  /// The chunk holding the resume episode, so the tab opens where the user left
  /// off instead of always at episode 1.
  int _initialRange() {
    if (!widget.hasAnyMark || widget.seasonEps.isEmpty) return 0;
    final resumeEp = widget.eps[widget.resumeIndex(widget.eps)];
    final local = widget.seasonEps.indexOf(resumeEp);
    return local < 0 ? 0 : local ~/ _chunk;
  }

  int get _rangeCount => (widget.seasonEps.length / _chunk).ceil();

  String _numLabel(Episode e, int fallback) =>
      (e.number?.toInt() ?? fallback).toString();

  /// Reading progress lives in [ReadStore] (page index / scroll permille),
  /// keyed by showId — the video [ResumeStore] never holds a mark for a
  /// chapter, so without this a read chapter could never dim. Also OR's in
  /// the connected tracker's chapter progress ([_EpisodesTab.trackerProgress]),
  /// same idea as [_stateFor]'s watched calc for video — a chapter you've
  /// only read on AniList/MAL should dim too. No seasons in reading, so no
  /// hasMultipleSeasons guard is needed here.
  ({bool watched, bool inProgress, bool resume, double fraction}) _readStateFor(
    Episode ep,
  ) {
    final store = sl<ReadStore>();
    final mark = store.get(widget.sourceId, widget.showId, ep.id);
    final done = store.finished(widget.sourceId, widget.showId, ep.id);
    final inProgress = mark != null && !done && mark.total > 0;
    final watched = done ||
        (widget.trackerProgress != null &&
            ep.number != null &&
            ep.number! <= widget.trackerProgress!);
    return (
      watched: watched,
      inProgress: inProgress,
      // No CONTINUE badge in the reading row, and the resume index we're
      // handed is the video one — so never claim a resume here.
      resume: false,
      fraction: inProgress ? (mark.pos / mark.total).clamp(0.0, 1.0) : 0.0,
    );
  }

  ({bool watched, bool inProgress, bool resume, double fraction}) _stateFor(
    ResumeStore store,
    Episode ep,
    int fullIndex,
  ) {
    if (widget.isReading) return _readStateFor(ep);
    final mark = store.get(widget.sourceId, widget.showUrl, ep.id);
    final inProgress =
        mark != null && !mark.finished && mark.duration > Duration.zero;
    // Watched = finished locally, OR at/below the tracker's watched count.
    // Only applied to single-season shows, where episode numbers map cleanly
    // to the tracker's per-entry progress (avoids mis-greying across seasons).
    final epNum = ep.number?.toInt();
    final watched = (mark != null && mark.finished) ||
        (widget.trackerProgress != null &&
            !widget.hasMultipleSeasons &&
            epNum != null &&
            epNum <= widget.trackerProgress!);
    final resume =
        widget.hasAnyMark && fullIndex == widget.resumeIndex(widget.eps);
    final fraction = inProgress
        ? (mark.position.inMilliseconds / mark.duration.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    return (
      watched: watched,
      inProgress: inProgress,
      resume: resume,
      fraction: fraction,
    );
  }

  Future<void> _jump() async {
    final n = await showDialog<int>(
      context: context,
      builder: (_) => const _JumpDialog(),
    );
    if (n == null || !mounted) return;
    // Match by episode number; fall back to a 1-based position.
    var local = widget.seasonEps.indexWhere((e) => e.number?.toInt() == n);
    if (local < 0 && n >= 1 && n <= widget.seasonEps.length) local = n - 1;
    if (local < 0) return;
    setState(() {
      _rangeIndex = local ~/ _chunk;
      _grid = true; // the grid makes the jumped-to episode easy to spot
      _highlightEpId = widget.seasonEps[local].id;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.seasonEps.isEmpty) {
      return const EmptyState(
        icon: Icons.video_library_outlined,
        message: 'No episodes available from this source',
      );
    }
    final store = sl<ResumeStore>();
    final total = widget.seasonEps.length;
    final start = (_rangeIndex * _chunk).clamp(0, total);
    final end = (start + _chunk).clamp(0, total);
    final visible = widget.seasonEps.sublist(start, end);
    final showRanges = _rangeCount > 1;

    // One scrollable (slivers): the header + chips scroll with the list so the
    // tab can never overflow when the NestedScrollView hands it a tiny height
    // during a layout pass (the Column+Expanded version did).
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _EpisodesHeader(
            hasMultipleSeasons: widget.hasMultipleSeasons,
            seasons: widget.seasonSet.toList()..sort(),
            currentSeason: widget.currentSeason,
            onSelectSeason: widget.onSelectSeason,
            onRefresh: widget.onRefresh,
            grid: _grid,
            onToggleView: () => setState(() => _grid = !_grid),
            onJump: showRanges ? _jump : null,
            isReading: widget.isReading,
          ),
        ),
        // Only when the tracker says the show is still airing. Sits under the
        // header so it reads as part of the episode list rather than another
        // thing competing with the hero.
        if (widget.nextAiringEpisode != null && widget.nextAiringAt != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                  children: [
                    TextSpan(text: 'Episode ${widget.nextAiringEpisode} '),
                    const TextSpan(text: 'airs in '),
                    // The countdown carries the weight — it's the part worth
                    // glancing at; the rest is scaffolding around it.
                    TextSpan(
                      text: airsIn(widget.nextAiringAt!, long: true),
                      style: AppText.body.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (showRanges)
          SliverToBoxAdapter(
            child: _RangeChips(
              count: _rangeCount,
              selected: _rangeIndex,
              labelFor: (i) {
                final s = (i * _chunk).clamp(0, total - 1);
                final e = ((i + 1) * _chunk - 1).clamp(0, total - 1);
                return '${_numLabel(widget.seasonEps[s], s + 1)}'
                    '–${_numLabel(widget.seasonEps[e], e + 1)}';
              },
              onSelect: (i) => setState(() {
                _rangeIndex = i;
                _highlightEpId = null;
              }),
            ),
          ),
        if (_grid)
          _buildGrid(store, visible, start)
        else
          _buildList(store, visible, start),
        const SliverToBoxAdapter(child: SizedBox(height: 48)),
      ],
    );
  }

  Widget _buildList(ResumeStore store, List<Episode> visible, int offset) {
    return SliverList.builder(
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final ep = visible[i];
        final fullIndex = widget.eps.indexOf(ep);
        final st = _stateFor(store, ep, fullIndex);
        final epNum = ep.number?.toInt() ?? (offset + i + 1);
        final displayTitle = widget.hasMultipleSeasons
            ? cleanTitle(ep.title)
            : ep.title;
        if (widget.isReading) {
          return RepaintBoundary(
            child: _ChapterRow(
              ep: ep,
              number: epNum,
              displayTitle: displayTitle,
              coverUrl: widget.coverUrl,
              coverHeaders: widget.coverHeaders,
              isRead: st.watched,
              isInProgress: st.inProgress,
              fraction: st.fraction,
              onTap: () => widget.onOpen(fullIndex),
              onDownload: () => widget.onDownload(ep),
              sourceId: widget.sourceId,
              showId: widget.showId,
              showDownload: widget.showDownload,
            ),
          );
        }
        return RepaintBoundary(
          child: _EpisodeRow(
            ep: ep,
            epNum: epNum,
            displayTitle: displayTitle,
            filler: widget.fillerEps.contains(epNum),
            coverUrl: widget.coverUrl,
            coverHeaders: widget.coverHeaders,
            isWatched: st.watched,
            isInProgress: st.inProgress,
            isResume: st.resume,
            fraction: st.fraction,
            onTap: () => widget.onOpen(fullIndex),
            onLongPress: widget.onPickPlayer == null
                ? null
                : () => widget.onPickPlayer!(fullIndex),
            onDownload: () => widget.onDownload(ep),
            sourceId: widget.sourceId,
            showId: widget.showId,
            showDownload: widget.showDownload,
          ),
        );
      },
    );
  }

  Widget _buildGrid(ResumeStore store, List<Episode> visible, int offset) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 1.15,
        ),
        itemCount: visible.length,
        itemBuilder: (context, i) {
          final ep = visible[i];
          final fullIndex = widget.eps.indexOf(ep);
          final st = _stateFor(store, ep, fullIndex);
          final epNum = ep.number?.toInt() ?? (offset + i + 1);
          return _EpisodeGridTile(
            number: epNum,
            isWatched: st.watched,
            isInProgress: st.inProgress,
            isResume: st.resume,
            isFiller: ep.filler,
            highlight: _highlightEpId == ep.id,
            fraction: st.fraction,
            onTap: () => widget.onOpen(fullIndex),
            onLongPress: widget.onPickPlayer == null
                ? null
                : () => widget.onPickPlayer!(fullIndex),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Episodes header — Netflix-style season dropdown (multi-season) that opens a
// dark bottom sheet to pick a season, or a plain "Episodes" label otherwise.
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodesHeader extends StatelessWidget {
  const _EpisodesHeader({
    required this.hasMultipleSeasons,
    required this.seasons,
    required this.currentSeason,
    required this.onSelectSeason,
    this.onRefresh,
    required this.grid,
    required this.onToggleView,
    this.onJump,
    this.isReading = false,
  });

  final bool hasMultipleSeasons;
  final List<int> seasons;
  final int currentSeason;
  final ValueChanged<int> onSelectSeason;

  /// Force-refresh the list past the source cache (header ↻); null hides it.
  final Future<void> Function()? onRefresh;

  /// Whether the grid view is active (toggles the view icon).
  final bool grid;
  final VoidCallback onToggleView;

  /// Jump-to-episode; null hides the button (short seasons don't need it).
  final VoidCallback? onJump;

  /// True for reading types — the single-season label reads "Chapters".
  final bool isReading;

  Widget _circle(IconData icon, VoidCallback onTap, {String? semanticLabel}) =>
      Semantics(
        button: true,
        label: semanticLabel,
        child: Material(
          color: AppColors.surface2,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(icon, color: AppColors.textPrimary, size: 20),
            ),
          ),
        ),
      );

  Future<void> _openSheet(BuildContext context) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surface,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) =>
          _SeasonSheet(seasons: seasons, currentSeason: currentSeason),
    );
    if (picked != null) onSelectSeason(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Row(
        children: [
          // Left: season dropdown pill (multi-season) or a plain label.
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: hasMultipleSeasons
                  ? Material(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(10),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _openSheet(context),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Season $currentSeason',
                                style: AppText.headline,
                              ),
                              const SizedBox(width: 6),
                              const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: AppColors.textPrimary,
                                size: 22,
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : Text(
                      isReading ? 'Chapters' : 'Episodes',
                      style: AppText.headline,
                    ),
            ),
          ),
          // Right: jump-to-episode (long seasons) · list/grid toggle · ⓘ info.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onJump != null) ...[
                _circle(
                  Icons.search_rounded,
                  onJump!,
                  semanticLabel: 'Find episode',
                ),
                const SizedBox(width: 8),
              ],
              _circle(
                grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                onToggleView,
                semanticLabel: grid ? 'List view' : 'Grid view',
              ),
              const SizedBox(width: 8),
              if (onRefresh != null) ...[
                _circle(
                  Icons.refresh_rounded,
                  () {
                    onRefresh!();
                    ScaffoldMessenger.of(context)
                      ..clearSnackBars()
                      ..showSnackBar(
                        SnackBar(
                          content: Text(
                            isReading
                                ? 'Refreshing chapters…'
                                : 'Refreshing episodes…',
                          ),
                          duration: const Duration(milliseconds: 1200),
                        ),
                      );
                  },
                  semanticLabel: isReading
                      ? 'Refresh chapters'
                      : 'Refresh episodes',
                ),
                const SizedBox(width: 8),
              ],
              // The ⓘ that used to sit here jumped to the Details tab — which
              // is a tap away in the tab bar directly above it. Two controls,
              // same destination, inches apart.
            ],
          ),
        ],
      ),
    );
  }
}

// Dark, rounded-top bottom sheet listing the available seasons with a coral
// check on the current one. Returns the picked season via Navigator.pop.
class _SeasonSheet extends StatelessWidget {
  const _SeasonSheet({required this.seasons, required this.currentSeason});

  final List<int> seasons;
  final int currentSeason;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grab handle.
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textTertiary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Seasons', style: AppText.title),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              itemCount: seasons.length,
              itemBuilder: (context0, i) {
                final s = seasons[i];
                final selected = s == currentSeason;
                return InkWell(
                  onTap: () => Navigator.of(context0).pop(s),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Season $s',
                            style: AppText.body.copyWith(
                              color: selected
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (selected)
                          Icon(
                            Icons.check_rounded,
                            color: AppColors.accent,
                            size: 22,
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Range chips — horizontal "1–50 / 51–100 / …" selector for long seasons so
// big anime stay navigable without endless scrolling. Selected chip is coral.
// ─────────────────────────────────────────────────────────────────────────────

class _RangeChips extends StatelessWidget {
  const _RangeChips({
    required this.count,
    required this.selected,
    required this.labelFor,
    required this.onSelect,
  });

  final int count;
  final int selected;
  final String Function(int) labelFor;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final sel = i == selected;
          return Material(
            color: sel ? AppColors.accent : AppColors.surface2,
            borderRadius: BorderRadius.circular(9),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onSelect(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Center(
                  child: Text(
                    labelFor(i),
                    style: AppText.caption.copyWith(
                      color: sel ? Colors.white : AppColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compact episode-number tile for the grid view — coral when it's the resume
// target, dimmed + ✓ when watched, a filler dot, and a resume bar when partly
// watched. Outlined briefly after a jump.
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodeGridTile extends StatelessWidget {
  const _EpisodeGridTile({
    required this.number,
    required this.isWatched,
    required this.isInProgress,
    required this.isResume,
    required this.isFiller,
    required this.highlight,
    required this.fraction,
    required this.onTap,
    this.onLongPress,
  });

  final int number;
  final bool isWatched;
  final bool isInProgress;
  final bool isResume;
  final bool isFiller;
  final bool highlight;
  final double fraction;
  final VoidCallback onTap;

  /// Long-press opens the "play this episode with" sheet. Optional so the
  /// reading path can leave it off — a chapter opens the reader, where a
  /// player picker has nothing to say.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final bg = isResume
        ? AppColors.accent
        : (isWatched ? AppColors.surface : AppColors.surface2);
    final fg = isResume
        ? Colors.white
        : (isWatched ? AppColors.textTertiary : AppColors.textPrimary);
    final side = highlight
        ? BorderSide(color: AppColors.accent, width: 2)
        : (isResume
              ? BorderSide.none
              : const BorderSide(color: AppColors.hairline, width: 0.5));

    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: side,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          children: [
            Center(
              child: Text(
                '$number',
                style: AppText.body.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (isWatched && !isResume)
              const Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  Icons.check_rounded,
                  size: 13,
                  color: AppColors.textTertiary,
                ),
              ),
            if (isFiller)
              const Positioned(
                top: 6,
                left: 6,
                child: SizedBox(
                  width: 6,
                  height: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.textTertiary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            if (isInProgress)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _ThumbnailProgressBar(fraction: fraction),
              ),
          ],
        ),
      ),
    );
  }
}

// Small number-input dialog for "jump to episode".
class _JumpDialog extends StatefulWidget {
  const _JumpDialog();

  @override
  State<_JumpDialog> createState() => _JumpDialogState();
}

class _JumpDialogState extends State<_JumpDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(int.tryParse(_ctrl.text.trim()));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('Go to episode', style: AppText.headline),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: 'Episode number',
          hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: AppText.body),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(
            'Go',
            style: AppText.body.copyWith(color: AppColors.accent),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reading (manga/novel) chapter row — the minimal counterpart to _EpisodeRow.
// A 44×62 portrait cover (the series art, dimmed once read), the chapter title
// with no "14." prefix (sources put the number in the title already), a muted
// meta line, and a hairline accent bar while a chapter is part-read. No play
// glyph, no tick, no badges — none of that means anything for a chapter.
//
// Deliberately a separate widget rather than a flag inside _EpisodeRow: it
// needs a third of _EpisodeRow's inputs, and this way the streaming row's code
// is untouched.
// ─────────────────────────────────────────────────────────────────────────────

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.ep,
    required this.number,
    required this.displayTitle,
    required this.coverUrl,
    required this.coverHeaders,
    required this.isRead,
    required this.isInProgress,
    required this.fraction,
    required this.onTap,
    required this.onDownload,
    required this.sourceId,
    required this.showId,
    this.showDownload = true,
  });

  /// Key on the portrait cover — the one structural marker that tells a
  /// chapter row apart from an episode row (see chapter row tests).
  static const coverKey = Key('chapterCover');

  final Episode ep;
  final int number;
  final String displayTitle;
  final String coverUrl;
  final Map<String, String>? coverHeaders;
  final bool isRead;
  final bool isInProgress;
  final double fraction;
  final VoidCallback onTap;
  final VoidCallback onDownload;
  final bool showDownload;
  final String sourceId;
  final String showId;

  @override
  Widget build(BuildContext context) {
    final title = displayTitle.trim().isNotEmpty
        ? displayTitle.trim()
        : 'Chapter $number';
    final meta = chapterMetaLine(ep);
    final art = (ep.thumbnail != null && ep.thumbnail!.isNotEmpty)
        ? ep.thumbnail!
        : coverUrl;

    return InkWell(
      onTap: onTap,
      splashColor: AppColors.accentSoft,
      highlightColor: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            SizedBox(
              key: coverKey,
              width: 44,
              height: 62,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Opacity(
                  opacity: isRead ? 0.45 : 1,
                  child: art.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: art,
                          httpHeaders: coverHeaders,
                          fit: BoxFit.cover,
                          memCacheWidth: 140,
                          placeholder: (c, u) =>
                              ColoredBox(color: AppColors.surface2),
                          errorWidget: (c, u, e) =>
                              ColoredBox(color: AppColors.surface2),
                        )
                      : ColoredBox(color: AppColors.surface2),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: AppText.body.copyWith(
                      color: isRead
                          ? AppColors.textTertiary
                          : AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // Dropped entirely when the source gives us nothing to put
                  // here, so the row shrinks instead of holding blank space.
                  if (meta != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      style: AppText.caption.copyWith(
                        color: isRead
                            ? AppColors.textTertiary
                            : AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (isInProgress && fraction > 0) ...[
                    const SizedBox(height: 6),
                    FractionallySizedBox(
                      widthFactor: fraction.clamp(0.0, 1.0),
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 2,
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Same rule as the episode row: hidden on TV, and hidden whenever
            // the caller says there's nothing downloadable (which is every
            // reading source today).
            if (!sl<AppMode>().isTv && showDownload) ...[
              const SizedBox(width: 8),
              _EpisodeDownloadIcon(
                sourceId: sourceId,
                showId: showId,
                episodeId: ep.id,
                onTap: onDownload,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Netflix episode block — a Column per episode (NO divider lines, whitespace
// instead):  Row[ rounded ~116px 16:9 thumb + centered play-circle (watched dim
// / ✓ / resume bar) | "N. Title" bold + date under + CONTINUE/FILLER badges |
// download icon ]  then, when the episode has a date, a muted line full-width
// below. Our model has no per-episode synopsis/duration, so we surface the air
// date in the below-row slot and omit it gracefully when absent (no faked data).
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.ep,
    required this.epNum,
    required this.displayTitle,
    required this.coverUrl,
    required this.coverHeaders,
    required this.isWatched,
    required this.isInProgress,
    required this.isResume,
    required this.fraction,
    required this.onTap,
    this.onLongPress,
    required this.onDownload,
    required this.sourceId,
    required this.showId,
    this.filler = false,
    this.showDownload = true,
  });

  final Episode ep;
  final int epNum;
  final String displayTitle;
  final bool filler;
  final String coverUrl;
  final Map<String, String>? coverHeaders;
  final bool isWatched;
  final bool isInProgress;
  final bool isResume;
  final double fraction;
  final VoidCallback onTap;

  /// Long-press opens the "play this episode with" sheet. Optional because the
  /// reading path reuses none of this — a chapter opens the reader, where a
  /// player picker has nothing to say.
  final VoidCallback? onLongPress;
  final VoidCallback onDownload;
  final bool showDownload;
  final String sourceId;
  final String showId;

  @override
  Widget build(BuildContext context) {
    final titleColor = isResume
        ? AppColors.accent
        : (isWatched ? AppColors.textSecondary : AppColors.textPrimary);

    final thumbUrl = (ep.thumbnail != null && ep.thumbnail!.isNotEmpty)
        ? ep.thumbnail!
        : coverUrl;

    // Air date stays as a small line next to the title; the episode synopsis
    // (AniZip/TMDB, ~3 lines) spans full width below the row — under the image
    // too, CloudStream-style.
    final desc = (ep.description != null && ep.description!.trim().isNotEmpty)
        ? ep.description!.trim()
        : null;
    // Runtime · air date. The rating now rides as a chip on the thumbnail
    // (always fully visible) instead of getting clipped on this cramped line.
    final metaLine = [
      if (ep.runtimeMinutes != null) '${ep.runtimeMinutes} min',
      if (ep.date != null && ep.date!.trim().isNotEmpty) ep.date!.trim(),
    ].join('  ·  ');

    // Prefer the real AniZip/TMDB title when the source only gave a generic
    // "Episode N" (or nothing); keep the source's own title when it has a real
    // one.
    final srcTitle = displayTitle.trim();
    final isGenericSrc =
        srcTitle.isEmpty ||
        srcTitle.toLowerCase() == 'episode $epNum' ||
        srcTitle.toLowerCase() == 'episode ${epNum.toString().padLeft(2, '0')}';
    final metaTitle = ep.metaTitle?.trim();
    final titleText = (isGenericSrc && metaTitle != null && metaTitle.isNotEmpty)
        ? metaTitle
        : srcTitle;
    final heading = titleText.isNotEmpty
        ? '$epNum. $titleText'
        : 'Episode $epNum';

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      splashColor: AppColors.accentSoft,
      highlightColor: AppColors.surface,
      child: Padding(
        // Generous vertical spacing between episodes (whitespace, no dividers).
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Rounded 16:9 thumbnail with a centered play-circle.
                SizedBox(
                  width: 116,
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          thumbUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: thumbUrl,
                                  httpHeaders: coverHeaders,
                                  fit: BoxFit.cover,
                                  memCacheWidth: 320,
                                  placeholder: (c, u) =>
                                      ColoredBox(color: AppColors.surface2),
                                  errorWidget: (c, u, e) =>
                                      ColoredBox(color: AppColors.surface2),
                                )
                              : ColoredBox(color: AppColors.surface2),
                          if (isWatched)
                            const DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0x73000000),
                              ),
                              child: SizedBox.expand(),
                            ),
                          // Centered play-circle (white ring like the ref).
                          const Center(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0x59000000),
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: EdgeInsets.all(7),
                                child: Icon(
                                  Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                            ),
                          ),
                          if (isWatched)
                            const Positioned(
                              top: 4,
                              right: 4,
                              child: Icon(
                                Icons.check_circle,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          // Rating chip — top-left so it never overlaps the
                          // watched check (top-right); always fully visible,
                          // unlike the old inline "★ 8.0" that got clipped.
                          if (ep.rating != null)
                            Positioned(
                              top: 4,
                              left: 4,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xB3000000),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 2,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.star_rounded,
                                        color: Color(0xFFFFC107),
                                        size: 11,
                                      ),
                                      const SizedBox(width: 2),
                                      Text(
                                        ep.rating!.toStringAsFixed(1),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          height: 1.1,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (isInProgress)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: _ThumbnailProgressBar(fraction: fraction),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // Title + date/duration under + badges.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        heading,
                        style: AppText.body.copyWith(
                          color: titleColor,
                          fontWeight: isResume
                              ? FontWeight.w800
                              : FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (metaLine.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          metaLine,
                          style: AppText.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (isResume || filler) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (isResume) const TagBadge(text: 'CONTINUE'),
                            if (isResume && filler) const SizedBox(width: 6),
                            if (filler) const TagBadge(text: 'FILLER'),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                // Per-episode download icon (phone only). On TV it's redundant
                // clutter next to the main Download button + hard to focus, so
                // it's hidden — the TV path downloads via the Download action.
                // Also hidden for reading types — a chapter has no video
                // source to download.
                if (!sl<AppMode>().isTv && showDownload) ...[
                  const SizedBox(width: 8),
                  _EpisodeDownloadIcon(
                    sourceId: sourceId,
                    showId: showId,
                    episodeId: ep.id,
                    onTap: onDownload,
                  ),
                ],
              ],
            ),
            // Full-width synopsis under the whole row (under the image too).
            if (desc != null) ...[
              const SizedBox(height: 8),
              Text(
                desc,
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontStyle: FontStyle.italic,
                  height: 1.4,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Per-episode download icon — self-updates from the DownloadManager so the
// row reflects live progress without the whole list rebuilding.
class _EpisodeDownloadIcon extends StatelessWidget {
  const _EpisodeDownloadIcon({
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
        final inProgress = rec != null &&
            (s == DownloadStatus.downloading ||
                s == DownloadStatus.paused ||
                s == DownloadStatus.queued ||
                s == DownloadStatus.resolving);
        return _glyph(
          s,
          rec?.progress ?? 0,
          onPressed: inProgress
              ? () => _showDownloadMenu(context, manager, rec)
              : onTap,
        );
      },
    );
  }

  Widget _glyph(
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
      DownloadStatus.done => 'Downloaded',
      DownloadStatus.downloading || DownloadStatus.paused => 'Downloading',
      DownloadStatus.queued || DownloadStatus.resolving => 'Downloading',
      DownloadStatus.unsupported => 'Download unsupported',
      DownloadStatus.failed => 'Retry download',
      _ => 'Download episode',
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
  void _showDownloadMenu(
    BuildContext context,
    DownloadManager manager,
    DownloadRecord rec,
  ) {
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
                paused ? 'Resume download' : 'Pause download',
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
                'Cancel download',
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
