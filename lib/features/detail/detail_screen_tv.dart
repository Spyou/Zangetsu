part of 'detail_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DetailScreenTv — two-pane landscape Detail for Android TV / large screens.
//
// Left pane  (fixed 300 px): poster + title + meta + focusable action buttons.
// Right pane (Expanded):     D-pad-navigable tab bar + tab content.
//
// Rendered in place of [_DetailView] when [AppMode.isTv] is true (gated at the
// top of [_DetailViewState.build]). Reads [DetailCubit] from context — the same
// [BlocProvider] created by [DetailScreen.build] covers both paths; no second
// cubit is created.
//
// Focus architecture (mirrors root_shell_tv.dart):
//   [_leftScope]  — wraps the left action column.
//   [_rightScope] — wraps the right tabs + content area.
//   arrowRight from left  → hand focus to the last-focused right child (or first
//                           traversable right descendant on first entry).
//   arrowLeft  from right → try intra-right traversal first; only cross over to
//                           the left pane when already at the left edge.
// ─────────────────────────────────────────────────────────────────────────────

class DetailScreenTv extends StatefulWidget {
  const DetailScreenTv({super.key, required this.item});
  final MediaItem item;

  @override
  State<DetailScreenTv> createState() => _DetailScreenTvState();
}

class _DetailScreenTvState extends State<DetailScreenTv> {
  int _tab = 0;
  static const _tabLabels = ['Episodes', 'Cast', 'Relations', 'Details'];

  // ── My List / status ──────────────────────────────────────────────────────
  final MyListStore _myList = sl<MyListStore>();
  final ListStatusStore _listStatus = sl<ListStatusStore>();
  late WatchStatus? _status;
  late bool _inMyList;

  // ── Left ↔ Right focus bridge ─────────────────────────────────────────────
  final FocusScopeNode _leftScope =
      FocusScopeNode(debugLabel: 'tv-detail-left');
  final FocusScopeNode _rightScope =
      FocusScopeNode(debugLabel: 'tv-detail-right');

  @override
  void initState() {
    super.initState();
    _status = _listStatus.statusOf(widget.item);
    _inMyList = _status != null || _myList.contains(widget.item);
    if (sl.isRegistered<DiscordRpc>()) {
      sl<DiscordRpc>().setBrowsing(
        title: widget.item.title,
        posterUrl: widget.item.cover,
      );
    }
  }

  @override
  void dispose() {
    if (sl.isRegistered<DiscordRpc>()) sl<DiscordRpc>().setBrowsing();
    _leftScope.dispose();
    _rightScope.dispose();
    super.dispose();
  }

  // D-pad RIGHT from the left pane → move into the right pane.
  KeyEventResult _onLeftKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      final last = _rightScope.focusedChild;
      if (last != null) {
        last.requestFocus();
      } else {
        _rightScope.traversalDescendants
            .where((n) => n.canRequestFocus)
            .firstOrNull
            ?.requestFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // D-pad LEFT from the right pane: try intra-pane traversal first; only
  // cross to the left pane when already at the left edge.
  KeyEventResult _onRightKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      final moved =
          FocusManager.instance.primaryFocus
              ?.focusInDirection(TraversalDirection.left) ??
          false;
      if (!moved) _leftScope.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── Resume index (identical to _DetailViewState._resumeIndex) ─────────────
  int _resumeIndex(List<Episode> eps) {
    final store = sl<ResumeStore>();
    int? highestMarked;
    for (int j = 0; j < eps.length; j++) {
      final mark =
          store.get(widget.item.sourceId, widget.item.url, eps[j].id);
      if (mark != null) highestMarked = j;
    }
    if (highestMarked == null) return 0;
    final mark = store.get(
      widget.item.sourceId,
      widget.item.url,
      eps[highestMarked].id,
    )!;
    if (!mark.finished) return highestMarked;
    if (highestMarked + 1 < eps.length) return highestMarked + 1;
    return highestMarked;
  }

  // ── Player launch (mirrors _DetailViewState._openPlayer exactly) ──────────
  void _openPlayer(
    List<Episode> episodes,
    int index,
    MediaDetail detail,
    String category,
  ) {
    final available = <String>[
      if ((detail.subCount ?? 0) > 0) 'sub',
      if ((detail.dubCount ?? 0) > 0) 'dub',
    ];
    final availableCategories = available.isEmpty ? [category] : available;
    final preferred =
        sl<TitlePrefsStore>().category(
          widget.item.sourceId,
          widget.item.url,
        ) ??
        sl<PlaybackPrefs>().defaultCategory;
    final launchCategory =
        availableCategories.contains(preferred) ? preferred : category;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          sourceId: widget.item.sourceId,
          episodes: episodes,
          startIndex: index,
          resume: sl<ResumeStore>(),
          resolveSources: (u) => sl<SourceRepository>().sources(
            u,
            sourceId: widget.item.sourceId,
            fast: true,
          ),
          history: sl<WatchHistory>(),
          showTitle: detail.title,
          cover: detail.cover ?? widget.item.cover,
          coverHeaders: detail.coverHeaders ?? widget.item.coverHeaders,
          showUrl: widget.item.url,
          category: launchCategory,
          malId: detail.malId ?? widget.item.malId,
          scrobbleTitle:
              detail.type == ProviderType.anime ? detail.title : null,
          tmdbId: detail.tmdbId ?? widget.item.tmdbId,
          tmdbIsTv: detail.tmdbIsTv,
          imdbId: detail.imdbId ?? widget.item.imdbId,
          availableCategories: availableCategories,
        ),
      ),
    );
  }

  Future<void> _openListSheet(MediaDetail detail) async {
    await showListStatusSheet(
      context,
      item: widget.item,
      malId: detail.malId ?? widget.item.malId,
      tmdbId: detail.tmdbId ?? widget.item.tmdbId,
      tmdbIsTv: detail.tmdbIsTv,
      imdbId: detail.imdbId ?? widget.item.imdbId,
      onChanged: () {
        if (!mounted) return;
        setState(() {
          _status = _listStatus.statusOf(widget.item);
          _inMyList = _status != null || _myList.contains(widget.item);
        });
      },
    );
  }

  Future<void> _openDownloadSheet({
    required MediaDetail detail,
    required String category,
    required Map<int, List<Episode>> episodesBySeason,
    required int initialSeason,
  }) async {
    final total =
        episodesBySeason.values.fold<int>(0, (a, b) => a + b.length);
    if (total == 0) {
      _snack('No episodes to download');
      return;
    }
    if (total == 1) {
      await _pickSourceAndDownload(
        episodesBySeason.values.first.first,
        detail,
        category,
      );
      return;
    }
    final availableCategories = <String>[
      if ((detail.subCount ?? 0) > 0) 'sub',
      if ((detail.dubCount ?? 0) > 0) 'dub',
    ];
    final res = await showModalBottomSheet<
      ({String quality, String category, List<Episode> episodes})
    >(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DownloadSheet(
        title: detail.title,
        episodesBySeason: episodesBySeason,
        initialSeason: initialSeason,
        initialCategory: category,
        availableCategories: availableCategories,
        coverUrl: detail.cover ?? widget.item.cover ?? '',
        coverHeaders: detail.coverHeaders ?? widget.item.coverHeaders,
        resolve: (ep) => sl<SourceRepository>().sources(
          ep.url,
          sourceId: widget.item.sourceId,
        ),
        resolveEpisodes: _episodesByCategory,
      ),
    );
    if (res == null || !mounted) return;
    _startDownload(detail, res.category, res.quality, res.episodes);
  }

  Future<Map<int, List<Episode>>> _episodesByCategory(String category) async {
    final d = await sl<SourceRepository>().detail(
      widget.item.url,
      category: category,
      sourceId: widget.item.sourceId,
    );
    final byS = <int, List<Episode>>{};
    for (final e in d.episodes) {
      (byS[parseSeason(e.title) ?? 1] ??= <Episode>[]).add(e);
    }
    if (byS.isEmpty) byS[1] = d.episodes;
    return byS;
  }

  Future<void> _pickSourceAndDownload(
    Episode ep,
    MediaDetail detail,
    String category,
  ) async {
    final item = widget.item;
    final res = await showModalBottomSheet<
      ({VideoSource chosen, List<VideoSource> all})
    >(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SourcePickerSheet(
        title: ep.title.trim().isNotEmpty ? ep.title : detail.title,
        resolve: () => sl<SourceRepository>().sources(
          ep.url,
          sourceId: item.sourceId,
        ),
      ),
    );
    if (res == null || !mounted) return;
    unawaited(
      sl<DownloadManager>().enqueueSource(
        sourceId: item.sourceId,
        showId: item.id,
        showTitle: detail.title,
        cover: detail.cover ?? item.cover,
        coverHeaders: detail.coverHeaders ?? item.coverHeaders,
        showUrl: item.url,
        category: category,
        episode: ep,
        source: res.chosen,
        qualityLabel: res.chosen.quality ?? 'auto',
        fallbacks: res.all,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        malId: detail.malId ?? item.malId,
      ),
    );
    _snack('Added to downloads');
  }

  void _startDownload(
    MediaDetail detail,
    String category,
    String quality,
    List<Episode> episodes,
  ) {
    final item = widget.item;
    unawaited(
      sl<DownloadManager>().enqueueEpisodes(
        sourceId: item.sourceId,
        showId: item.id,
        showTitle: detail.title,
        cover: detail.cover ?? item.cover,
        coverHeaders: detail.coverHeaders ?? item.coverHeaders,
        showUrl: item.url,
        category: category,
        quality: quality,
        episodes: episodes,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        malId: detail.malId ?? item.malId,
      ),
    );
    _snack(
      episodes.length == 1
          ? 'Added to downloads'
          : 'Downloading ${episodes.length} episodes',
    );
  }

  Future<void> _openRelation(MediaRelation r) async {
    _snack('Finding "${r.title}"…');
    try {
      final results = await sl<SourceRepository>().search(
        r.title,
        sourceId: widget.item.sourceId,
      );
      if (!mounted) return;
      if (results.isEmpty) {
        _snack('"${r.title}" isn\'t on this source');
        return;
      }
      Navigator.of(context).push(DetailScreen.route(results.first));
    } catch (_) {
      if (mounted) _snack('Couldn\'t open "${r.title}"');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: AppText.caption.copyWith(color: Colors.white),
          ),
          backgroundColor: AppColors.surface2,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DetailCubit, DetailState>(
      builder: (context, state) {
        if (state.status == DetailStatus.loading) {
          return const Scaffold(
            backgroundColor: AppColors.bg,
            body: Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            ),
          );
        }
        if (state.status == DetailStatus.error || state.detail == null) {
          return const Scaffold(
            backgroundColor: AppColors.bg,
            body: EmptyState(
              icon: Icons.error_outline,
              message: 'Failed to load this title',
            ),
          );
        }
        return _buildTwoPane(context, state, state.detail!);
      },
    );
  }

  Widget _buildTwoPane(
    BuildContext context,
    DetailState state,
    MediaDetail detail,
  ) {
    final item = widget.item;
    final category = state.category;
    final eps = detail.episodes;
    final store = sl<ResumeStore>();

    // Resume / play label (mirrors _DetailViewState._buildBody).
    final resumeIdx = _resumeIndex(eps);
    final hasAnyMark =
        eps.any((e) => store.get(item.sourceId, item.url, e.id) != null);
    final episodeNum = eps.isNotEmpty
        ? (eps[resumeIdx].number?.toInt() ?? resumeIdx + 1)
        : 1;
    final buttonLabel = hasAnyMark ? 'Continue E$episodeNum' : 'Play';

    // Cover.
    final coverUrl = detail.cover ?? item.cover ?? '';
    final coverHeaders = detail.coverHeaders ?? item.coverHeaders;

    // Season data (mirrors _DetailViewState._buildBody).
    final seasonSet = seasonsOf(eps);
    final hasMultipleSeasons = seasonSet.length > 1;
    final currentSeason = hasMultipleSeasons
        ? (seasonSet.contains(state.selectedSeason)
              ? state.selectedSeason
              : seasonSet.first)
        : 1;
    final seasonEps = hasMultipleSeasons
        ? eps.where((e) => parseSeason(e.title) == currentSeason).toList()
        : eps;

    final episodesBySeason = <int, List<Episode>>{};
    if (hasMultipleSeasons) {
      for (final e in eps) {
        (episodesBySeason[parseSeason(e.title) ?? 1] ??= <Episode>[]).add(e);
      }
    } else {
      episodesBySeason[1] = eps;
    }

    final sourceName = _sourceLabel(item.sourceId);
    final statusStr = statusLabel(detail.status);

    // Meta line (mirrors _DetailViewState._buildBody).
    final metaParts = <String>[];
    if ((detail.year ?? '').isNotEmpty) metaParts.add(detail.year!);
    if (hasMultipleSeasons) {
      metaParts.add('${seasonSet.length} Seasons');
    } else if (eps.isNotEmpty) {
      metaParts.add('${eps.length} Episode${eps.length == 1 ? '' : 's'}');
    }
    if (statusStr.isNotEmpty) metaParts.add(statusStr);
    final metaLine = metaParts.join('  ·  ');

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── LEFT pane: poster + title + meta + action buttons ─────────
            Focus(
              focusNode: _leftScope,
              onKeyEvent: _onLeftKey,
              child: SizedBox(
                width: 300,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Poster (2:3 aspect, fills available space)
                    Expanded(
                      flex: 5,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: coverUrl.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: coverUrl,
                                  httpHeaders: coverHeaders,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  memCacheWidth: 400,
                                  placeholder: (_, _) => const ColoredBox(
                                    color: AppColors.surface2,
                                  ),
                                  errorWidget: (_, _, _) => const ColoredBox(
                                    color: AppColors.surface2,
                                  ),
                                )
                              : const ColoredBox(color: AppColors.surface2),
                        ),
                      ),
                    ),
                    // Title + meta + action buttons
                    Expanded(
                      flex: 4,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 14, 12, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              detail.title,
                              style: AppText.headline.copyWith(fontSize: 18),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (metaLine.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                metaLine,
                                style: AppText.caption.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            const SizedBox(height: 16),
                            // Play button — autofocus: always the first focused
                            // element when the detail screen opens on TV.
                            TvFocusable(
                              key: const ValueKey('tv-detail-play'),
                              autofocus: true,
                              onTap: eps.isNotEmpty
                                  ? () => _openPlayer(
                                      eps,
                                      resumeIdx,
                                      detail,
                                      category,
                                    )
                                  : () {},
                              child: _PlayButton(
                                label: buttonLabel,
                                onPressed: eps.isNotEmpty
                                    ? () => _openPlayer(
                                        eps,
                                        resumeIdx,
                                        detail,
                                        category,
                                      )
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 10),
                            // Download button
                            TvFocusable(
                              key: const ValueKey('tv-detail-download'),
                              onTap: () => _openDownloadSheet(
                                detail: detail,
                                category: category,
                                episodesBySeason: episodesBySeason,
                                initialSeason: currentSeason,
                              ),
                              child: _DownloadButton(
                                label: 'Download',
                                onPressed: () => _openDownloadSheet(
                                  detail: detail,
                                  category: category,
                                  episodesBySeason: episodesBySeason,
                                  initialSeason: currentSeason,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            // My List button (same icon-over-label as phone)
                            TvFocusable(
                              key: const ValueKey('tv-detail-mylist'),
                              onTap: () => _openListSheet(detail),
                              child: _IconAction(
                                icon: _inMyList
                                    ? Icons.check_rounded
                                    : Icons.add_rounded,
                                active: _inMyList,
                                label: _status?.shortLabel ?? 'My List',
                                tooltip: _inMyList
                                    ? 'Change status'
                                    : 'Add to My List',
                                onTap: () => _openListSheet(detail),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 1, color: AppColors.hairline),
            // ── RIGHT pane: focusable tab bar + content ────────────────────
            Expanded(
              child: Focus(
                focusNode: _rightScope,
                onKeyEvent: _onRightKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Tab bar — each label is a TvFocusable. Wrapped in a
                    // horizontal scroll so it never overflows on narrow screens.
                    SizedBox(
                      height: 56,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                        child: Row(
                          children: [
                            for (int i = 0; i < _tabLabels.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: TvFocusable(
                                key: ValueKey('tv-detail-tab-$i'),
                                onTap: () => setState(() => _tab = i),
                                scale: 1.04,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    _tabLabels[i],
                                    style: AppText.headline.copyWith(
                                      fontSize: 15,
                                      color: _tab == i
                                          ? AppColors.accent
                                          : AppColors.textSecondary,
                                      fontWeight: _tab == i
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                    const Divider(height: 1, color: AppColors.hairline),
                    // Tab content
                    Expanded(
                      child: IndexedStack(
                        index: _tab,
                        children: [
                          // ── Episodes ──────────────────────────────────────
                          _TvEpisodeList(
                            key: const ValueKey('tv-detail-episodes'),
                            eps: eps,
                            seasonEps: seasonEps,
                            sourceId: item.sourceId,
                            showId: item.id,
                            showUrl: item.url,
                            coverUrl: coverUrl,
                            coverHeaders: coverHeaders,
                            hasAnyMark: hasAnyMark,
                            resumeIndex: _resumeIndex,
                            onOpen: (i) =>
                                _openPlayer(eps, i, detail, category),
                            onDownload: (ep) {},
                          ),
                          // ── Cast ─────────────────────────────────────────
                          _CastTab(
                            cast: state.cast.isNotEmpty
                                ? state.cast
                                : [
                                    for (final n in detail.cast)
                                      CastMember(name: n),
                                  ],
                          ),
                          // ── Relations ──────────────────────────────────
                          _RelationsTab(
                            relations: state.relations,
                            onOpen: _openRelation,
                          ),
                          // ── Details ────────────────────────────────────
                          _DetailsTab(
                            sourceName: sourceName,
                            statusStr: statusStr,
                            genres: detail.genres,
                            studios: detail.studios,
                            episodeCount: eps.length,
                            year: detail.year,
                            description: detail.description,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TV episode list — each row is a [TvFocusable]-wrapped [_EpisodeRow] so
// D-pad up/down + OK navigates and plays. Simpler than [_EpisodesTab] (no
// season dropdown, range chips, or grid toggle — touch-only affordances are
// omitted from the TV path). Uses the SAME [_EpisodeRow] widget the phone
// Detail uses, so the visual design is byte-for-byte identical.
// ─────────────────────────────────────────────────────────────────────────────

class _TvEpisodeList extends StatelessWidget {
  const _TvEpisodeList({
    super.key,
    required this.eps,
    required this.seasonEps,
    required this.sourceId,
    required this.showId,
    required this.showUrl,
    required this.coverUrl,
    required this.coverHeaders,
    required this.hasAnyMark,
    required this.resumeIndex,
    required this.onOpen,
    required this.onDownload,
  });

  final List<Episode> eps;
  final List<Episode> seasonEps;
  final String sourceId;
  final String showId;
  final String showUrl;
  final String coverUrl;
  final Map<String, String>? coverHeaders;
  final bool hasAnyMark;
  final int Function(List<Episode>) resumeIndex;
  final void Function(int fullIndex) onOpen;
  final void Function(Episode ep) onDownload;

  @override
  Widget build(BuildContext context) {
    if (seasonEps.isEmpty) {
      return const EmptyState(
        icon: Icons.video_library_outlined,
        message: 'No episodes available from this source',
      );
    }
    final store = sl<ResumeStore>();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 32),
      itemCount: seasonEps.length,
      itemBuilder: (context, i) {
        final ep = seasonEps[i];
        final fullIndex = eps.indexOf(ep);
        final mark = store.get(sourceId, showUrl, ep.id);
        final inProgress =
            mark != null &&
            !mark.finished &&
            mark.duration > Duration.zero;
        final watched = mark != null && mark.finished;
        final resume = hasAnyMark && fullIndex == resumeIndex(eps);
        final fraction = inProgress
            ? (mark.position.inMilliseconds / mark.duration.inMilliseconds)
                  .clamp(0.0, 1.0)
            : 0.0;
        final epNum = ep.number?.toInt() ?? (i + 1);

        // Wrap the existing _EpisodeRow in TvFocusable so D-pad up/down +
        // OK-select navigates + triggers playback. The inner InkWell (touch)
        // still works; both paths fire the same callback.
        return TvFocusable(
          key: ValueKey('tv-ep-$i'),
          onTap: () => onOpen(fullIndex),
          child: RepaintBoundary(
            child: _EpisodeRow(
              ep: ep,
              epNum: epNum,
              displayTitle: ep.title,
              coverUrl: coverUrl,
              coverHeaders: coverHeaders,
              isWatched: watched,
              isInProgress: inProgress,
              isResume: resume,
              fraction: fraction,
              onTap: () => onOpen(fullIndex),
              onDownload: () => onDownload(ep),
              sourceId: sourceId,
              showId: showId,
            ),
          ),
        );
      },
    );
  }
}
