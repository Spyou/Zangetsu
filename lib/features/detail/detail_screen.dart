import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/badge.dart';
import '../../core/ui/brand_loader.dart';
import '../../core/ui/buttons.dart';
import '../../core/ui/segmented_toggle.dart';
import '../../core/ui/states.dart';
import '../player/player_screen.dart';
import 'cubit/detail_cubit.dart';

class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key, required this.item});
  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => DetailCubit(
        repo: sl<SourceRepository>(),
        url: item.url,
        sourceId: item.sourceId,
        prefs: sl<TitlePrefsStore>(),
      )..load(),
      child: _DetailView(item: item),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _DetailView — StatefulWidget for the scroll-driven app-bar title fade.
// The scroll position is pure UI state and stays widget-level; everything
// data-related (detail / category / season / desc-expand) lives in
// DetailCubit and is consumed via BlocBuilder below.
// ─────────────────────────────────────────────────────────────────────────────

class _DetailView extends StatefulWidget {
  const _DetailView({required this.item});
  final MediaItem item;

  @override
  State<_DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends State<_DetailView> {
  static const double _expandedHeight = 360;
  bool _showAppBarTitle = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Smoothly reveal the bottom "Details" section.
  void _scrollToDetails() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOut,
    );
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final shouldShow = n.metrics.pixels > (_expandedHeight - kToolbarHeight - 24);
    if (shouldShow != _showAppBarTitle) {
      setState(() => _showAppBarTitle = shouldShow);
    }
    return false;
  }

  // ── My List toggle (visual-only addition; behavior preserved elsewhere) ───
  final MyListStore _myList = sl<MyListStore>();
  late bool _inMyList = _myList.contains(widget.item);

  Future<void> _toggleMyList() async {
    await _myList.toggle(widget.item);
    if (!mounted) return;
    setState(() => _inMyList = _myList.contains(widget.item));
  }

  // ── Preserved exactly from original ──────────────────────────────────────

  void _openPlayer(
    List<Episode> episodes,
    int index,
    MediaDetail detail,
    String category,
  ) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        sourceId: widget.item.sourceId,
        episodes: episodes,
        startIndex: index,
        resume: sl<ResumeStore>(),
        resolveSources: (u) =>
            sl<SourceRepository>().sources(u, sourceId: widget.item.sourceId),
        history: sl<WatchHistory>(),
        showTitle: detail.title,
        cover: detail.cover ?? widget.item.cover,
        coverHeaders: detail.coverHeaders ?? widget.item.coverHeaders,
        showUrl: widget.item.url,
        category: category,
      ),
    ));
  }

  /// Walk episodes and return the best resume target index.
  /// - No marks → 0 ("Play")
  /// - Highest marked & not finished → that index ("Continue EN")
  /// - Highest marked & finished + next exists → next index ("Continue EN+1")
  /// - Highest marked & finished & last → same index ("Continue EN")
  int _resumeIndex(List<Episode> eps) {
    final store = sl<ResumeStore>();
    int? highestMarked;
    for (int j = 0; j < eps.length; j++) {
      final mark = store.get(widget.item.sourceId, eps[j].id);
      if (mark != null) {
        highestMarked = j;
      }
    }
    if (highestMarked == null) return 0;
    final mark = store.get(widget.item.sourceId, eps[highestMarked].id)!;
    if (!mark.finished) return highestMarked;
    if (highestMarked + 1 < eps.length) return highestMarked + 1;
    return highestMarked;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: BlocBuilder<DetailCubit, DetailState>(
        builder: (context, state) {
          if (state.status == DetailStatus.loading) {
            return const Center(child: BrandLoader(label: 'Loading…'));
          }
          if (state.status == DetailStatus.error || state.detail == null) {
            return const EmptyState(
              icon: Icons.error_outline,
              message: 'Failed to load this title',
            );
          }
          return _buildBody(context, state, state.detail!);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, DetailState state, MediaDetail detail) {
    final item = widget.item;
    final cubit = context.read<DetailCubit>();
    final category = state.category;
    final audioIndex = category == 'sub' ? 0 : 1;
    final descExpanded = state.descExpanded;
    final selectedSeason = state.selectedSeason;
    final showSubDub = showSubDubFor(detail);
    final eps = detail.episodes;
    final store = sl<ResumeStore>();

    // Resume / play button logic
    final resumeIdx = _resumeIndex(eps);
    final hasAnyMark =
        eps.any((e) => store.get(item.sourceId, e.id) != null);
    final episodeNum = eps.isNotEmpty
        ? (eps[resumeIdx].number?.toInt() ?? resumeIdx + 1)
        : 1;
    final buttonLabel = hasAnyMark ? 'Continue E$episodeNum' : 'Play';

    // Cover
    final coverUrl = detail.cover ?? item.cover ?? '';
    final coverHeaders = detail.coverHeaders ?? item.coverHeaders;
    final hasCover = coverUrl.isNotEmpty;

    // Season data
    final seasonSet = seasonsOf(eps);
    final hasMultipleSeasons = seasonSet.length > 1;

    // Season to display (clamp in case detail reloads with fewer seasons)
    final currentSeason = hasMultipleSeasons
        ? (seasonSet.contains(selectedSeason) ? selectedSeason : seasonSet.first)
        : 1;

    // Episodes filtered by season
    final seasonEps = hasMultipleSeasons
        ? eps
            .where((e) => parseSeason(e.title) == currentSeason)
            .toList()
        : eps;

    // Meta row
    final statusStr = statusLabel(detail.status);
    final metaParts = <String>['${eps.length} Episodes'];
    if (statusStr.isNotEmpty) metaParts.add(statusStr);
    if (detail.genres.isNotEmpty) metaParts.add(detail.genres.first);
    final metaLine = metaParts.join(' · ');

    // Friendly provider name for the source chip + Details section.
    final sourceName =
        sl<ProviderRegistry>().entryFor(item.sourceId)?.displayName ??
            item.sourceId;

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: CustomScrollView(
      controller: _scrollController,
      slivers: [
        // ── 1. Cinematic hero SliverAppBar ─────────────────────────────────
        SliverAppBar(
          expandedHeight: _expandedHeight,
          pinned: true,
          stretch: true,
          backgroundColor: AppColors.bg,
          surfaceTintColor: Colors.transparent,
          // Fades in only once the hero cover has scrolled out of view —
          // mirrors Sozo Read's NotificationListener-driven pattern.
          title: AnimatedOpacity(
            opacity: _showAppBarTitle ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: Text(
              detail.title,
              style: AppText.headline,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          flexibleSpace: FlexibleSpaceBar(
            collapseMode: CollapseMode.parallax,
            background: RepaintBoundary(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Backdrop cover
                  hasCover
                      ? CachedNetworkImage(
                          imageUrl: coverUrl,
                          httpHeaders: coverHeaders,
                          fit: BoxFit.cover,
                          memCacheWidth: 800,
                          placeholder: (context0, url0) =>
                              const ColoredBox(color: AppColors.surface2),
                          errorWidget: (context0, url0, err) =>
                              const ColoredBox(color: AppColors.surface2),
                        )
                      : const ColoredBox(color: AppColors.surface2),
                  // Top scrim (status-bar legibility)
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: AppColors.topScrim,
                    ),
                  ),
                  // Bottom-up scrim
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: AppColors.scrim,
                    ),
                  ),
                  // Cinematic poster + title block at the bottom.
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 20,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // Crisp 2:3 poster with rounded corners + soft elevation.
                        SizedBox(
                          height: 168,
                          child: AspectRatio(
                            aspectRatio: 2 / 3,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x80000000),
                                    blurRadius: 20,
                                    offset: Offset(0, 8),
                                  ),
                                ],
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08),
                                  width: 0.5,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: hasCover
                                    ? CachedNetworkImage(
                                        imageUrl: coverUrl,
                                        httpHeaders: coverHeaders,
                                        fit: BoxFit.cover,
                                        memCacheWidth: 240,
                                        placeholder: (context0, url0) =>
                                            const ColoredBox(
                                                color: AppColors.surface2),
                                        errorWidget: (context0, url0, err) =>
                                            const ColoredBox(
                                                color: AppColors.surface2),
                                      )
                                    : const ColoredBox(
                                        color: AppColors.surface2),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        // Title + meta block.
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  detail.title,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontFamily: 'Inter',
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.4,
                                    height: 1.12,
                                    shadows: [
                                      Shadow(
                                        blurRadius: 8,
                                        color: Colors.black,
                                      ),
                                    ],
                                  ),
                                ),
                                if ((detail.englishTitle ?? '').isNotEmpty &&
                                    detail.englishTitle != detail.title) ...[
                                  const SizedBox(height: 5),
                                  Text(
                                    detail.englishTitle!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontFamily: 'Inter',
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      height: 1.25,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 10),
                                if (detail.status != MediaStatus.unknown)
                                  _StatusBadge(status: detail.status),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // ── 2. Header block ─────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: RepaintBoundary(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Source chip + meta row. Title lives only in the hero +
                  // fading app-bar; the chip surfaces WHICH provider this title
                  // came from (AllAnime / Netflix / …).
                  Row(
                    children: [
                      if (sourceName.isNotEmpty) ...[
                        TagBadge(text: sourceName),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Text(
                          metaLine,
                          style: AppText.caption.copyWith(
                              color: AppColors.textSecondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Play / Continue button
                  PrimaryButton(
                    label: buttonLabel,
                    icon: Icons.play_arrow_rounded,
                    onPressed: eps.isNotEmpty
                        ? () => _openPlayer(eps, resumeIdx, detail, category)
                        : null,
                  ),
                  const SizedBox(height: 12),
                  // Netflix-style secondary action row (icon-over-label).
                  Row(
                    children: [
                      Expanded(
                        child: _ActionButton(
                          icon: _inMyList
                              ? Icons.check_rounded
                              : Icons.add_rounded,
                          label: 'My List',
                          active: _inMyList,
                          onTap: _toggleMyList,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _ActionButton(
                          icon: Icons.info_outline_rounded,
                          label: 'Details',
                          onTap: () => _scrollToDetails(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Sub / Dub toggle — anime only, when both counts are meaningful
                  if (showSubDub) ...[
                    SegmentedToggle(
                      segments: const ['Sub', 'Dub'],
                      index: audioIndex,
                      onChanged: (i) =>
                          cubit.setCategory(i == 0 ? 'sub' : 'dub'),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Description with "More" affordance
                  if ((detail.description ?? '').isNotEmpty) ...[
                    GestureDetector(
                      onTap: cubit.toggleDesc,
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnimatedSize(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                            alignment: Alignment.topCenter,
                            child: Text(
                              detail.description!,
                              style: AppText.body,
                              maxLines: descExpanded ? null : 3,
                              overflow: descExpanded
                                  ? TextOverflow.visible
                                  : TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            descExpanded ? 'Show less' : 'Show more',
                            style: AppText.caption.copyWith(
                              color: AppColors.accent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  // Genre chips
                  if (detail.genres.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: detail.genres
                          .map((g) => TagBadge(
                                text: g,
                                color: AppColors.textSecondary,
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const Divider(color: AppColors.hairline, height: 1),
                  const SizedBox(height: 16),
                  // "Episodes" heading + count.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      const Text('Episodes', style: AppText.title),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          '${seasonEps.length}',
                          style: AppText.caption.copyWith(
                            color: AppColors.textTertiary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),

        // ── 3. Season selector (only when multi-season) ─────────────────────
        if (hasMultipleSeasons)
          SliverToBoxAdapter(
            child: _SeasonSelector(
              seasons: seasonSet.toList()..sort(),
              selectedSeason: currentSeason,
              onSelectSeason: cubit.selectSeason,
            ),
          ),

        // ── 4. Netflix/Prime-style episode list ──────────────────────────────
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final ep = seasonEps[i];
              // Map season-filtered index back to the FULL episode list index
              // so playback / resume keys remain correct.
              final fullIndex = eps.indexOf(ep);
              final mark = store.get(item.sourceId, ep.id);
              final isInProgress = mark != null &&
                  !mark.finished &&
                  mark.duration > Duration.zero;
              final isWatched = mark != null && mark.finished;
              final isResume = hasAnyMark && fullIndex == _resumeIndex(eps);

              final fraction = isInProgress
                  ? (mark.position.inMilliseconds /
                          mark.duration.inMilliseconds)
                      .clamp(0.0, 1.0)
                  : 0.0;

              final epNumStr =
                  'E${ep.number?.toInt() ?? i + 1}';
              final rawTitle = ep.title;
              final displayTitle = hasMultipleSeasons
                  ? cleanTitle(rawTitle)
                  : rawTitle;

              return RepaintBoundary(
                child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _EpisodeRow(
                    ep: ep,
                    epNumStr: epNumStr,
                    displayTitle: displayTitle,
                    coverUrl: coverUrl,
                    coverHeaders: coverHeaders,
                    isWatched: isWatched,
                    isInProgress: isInProgress,
                    isResume: isResume,
                    fraction: fraction,
                    onTap: () => _openPlayer(eps, fullIndex, detail, category),
                  ),
                  if (i < seasonEps.length - 1)
                    const Divider(
                      height: 1,
                      thickness: 0,
                      color: AppColors.hairline,
                      indent: 16,
                      endIndent: 16,
                    ),
                ],
              ),
              );
            },
            childCount: seasonEps.length,
          ),
        ),

        // ── 5. Sozo-style "Details" section ──────────────────────────────────
        SliverToBoxAdapter(
          child: _DetailsSection(
            sourceName: sourceName,
            statusStr: statusStr,
            genres: detail.genres,
            episodeCount: eps.length,
            description: detail.description,
          ),
        ),

        // Bottom padding
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Season selector — horizontal pill chips
// ─────────────────────────────────────────────────────────────────────────────

class _SeasonSelector extends StatelessWidget {
  const _SeasonSelector({
    required this.seasons,
    required this.selectedSeason,
    required this.onSelectSeason,
  });

  final List<int> seasons;
  final int selectedSeason;
  final ValueChanged<int> onSelectSeason;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: seasons.length,
          separatorBuilder: (context0, i0) => const SizedBox(width: 8),
          itemBuilder: (context0, i) {
            final s = seasons[i];
            final selected = s == selectedSeason;
            return GestureDetector(
              onTap: () => onSelectSeason(s),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                decoration: BoxDecoration(
                  color: selected ? AppColors.accentSoft : AppColors.surface2,
                  borderRadius: BorderRadius.circular(19),
                  border: Border.all(
                    color: selected ? AppColors.accent : AppColors.hairline,
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Season $s',
                  style: AppText.caption.copyWith(
                    color:
                        selected ? AppColors.accent : AppColors.textSecondary,
                    fontWeight:
                        selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sozo-style "Details" section — inline (no tabs). Surfaces source / status /
// genres / episode count + the FULL (un-truncated) synopsis. The header still
// shows the 3-line + More/Less; this is the complete reference block.
// ─────────────────────────────────────────────────────────────────────────────

class _DetailsSection extends StatelessWidget {
  const _DetailsSection({
    required this.sourceName,
    required this.statusStr,
    required this.genres,
    required this.episodeCount,
    required this.description,
  });

  final String sourceName;
  final String statusStr;
  final List<String> genres;
  final int episodeCount;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final desc = description ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(color: AppColors.hairline, height: 1),
          const SizedBox(height: 20),
          Text('DETAILS', style: AppText.overline),
          const SizedBox(height: 16),
          if (sourceName.isNotEmpty)
            _DetailRow(label: 'Source', value: sourceName),
          if (statusStr.isNotEmpty)
            _DetailRow(label: 'Status', value: statusStr),
          _DetailRow(label: 'Episodes', value: '$episodeCount'),
          if (genres.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'Genres',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: genres
                  .map((g) => TagBadge(text: g, color: AppColors.textSecondary))
                  .toList(),
            ),
          ],
          if (desc.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'Synopsis',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
            const SizedBox(height: 8),
            Text(desc, style: AppText.body),
          ],
        ],
      ),
    );
  }
}

/// One label/value line in the Details section.
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppText.caption.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Netflix/Prime-style episode row — landscape thumbnail + meta
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.ep,
    required this.epNumStr,
    required this.displayTitle,
    required this.coverUrl,
    required this.coverHeaders,
    required this.isWatched,
    required this.isInProgress,
    required this.isResume,
    required this.fraction,
    required this.onTap,
  });

  final Episode ep;
  final String epNumStr;
  final String displayTitle;
  final String coverUrl;
  final Map<String, String>? coverHeaders;
  final bool isWatched;
  final bool isInProgress;
  final bool isResume;
  final double fraction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final titleColor = isResume
        ? AppColors.accent
        : (isWatched ? AppColors.textSecondary : AppColors.textPrimary);

    final thumbUrl =
        (ep.thumbnail != null && ep.thumbnail!.isNotEmpty)
            ? ep.thumbnail!
            : coverUrl;

    // A graceful 1-line muted detail when we have a synopsis-like field.
    // Most episodes only carry an air date — show it when present, omit
    // otherwise (no empty placeholder rows).
    final subline = (ep.date != null && ep.date!.trim().isNotEmpty)
        ? ep.date!.trim()
        : null;

    return InkWell(
      onTap: onTap,
      splashColor: AppColors.accentSoft,
      highlightColor: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 16:9 thumbnail
            SizedBox(
              width: 136,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x4D000000),
                        blurRadius: 8,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
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
                                memCacheWidth: 272,
                                placeholder: (context0, url0) =>
                                    const ColoredBox(
                                        color: AppColors.surface2),
                                errorWidget: (context0, url0, err) =>
                                    const ColoredBox(
                                        color: AppColors.surface2),
                              )
                            : const ColoredBox(color: AppColors.surface2),
                        // Dim watched thumbnails so progress reads clearly.
                        if (isWatched)
                          const DecoratedBox(
                            decoration: BoxDecoration(color: Color(0x73000000)),
                            child: SizedBox.expand(),
                          ),
                        // Play glyph overlay
                        const Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0x66000000),
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                        // Watched check overlay (top-right)
                        if (isWatched)
                          const Positioned(
                            top: 5,
                            right: 5,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0xAA000000),
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: EdgeInsets.all(2),
                                child: Icon(
                                  Icons.check_rounded,
                                  color: Colors.white,
                                  size: 13,
                                ),
                              ),
                            ),
                          ),
                        // Resume progress bar at the bottom of thumb
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
            ),
            const SizedBox(width: 14),
            // Meta column
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Episode number + badges row
                  Row(
                    children: [
                      Text(
                        epNumStr,
                        style: AppText.headline.copyWith(
                          color: titleColor,
                          fontWeight:
                              isResume ? FontWeight.w800 : FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (isResume)
                        const TagBadge(text: 'CONTINUE'),
                      if (ep.filler) ...[
                        if (isResume) const SizedBox(width: 6),
                        const TagBadge(
                          text: 'FILLER',
                          color: AppColors.textTertiary,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Episode title
                  if (displayTitle.isNotEmpty)
                    Text(
                      displayTitle,
                      style: AppText.body.copyWith(
                        color: isWatched
                            ? AppColors.textTertiary
                            : AppColors.textSecondary,
                        fontSize: 14,
                        height: 1.3,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  // Muted 1-line subline (air date) when available.
                  if (subline != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subline,
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Thin accent progress bar painted at the bottom of a thumbnail
// ─────────────────────────────────────────────────────────────────────────────

class _ThumbnailProgressBar extends StatelessWidget {
  const _ThumbnailProgressBar({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 4,
      child: Stack(
        children: [
          const ColoredBox(
              color: Color(0x80000000), child: SizedBox.expand()),
          FractionallySizedBox(
            widthFactor: fraction,
            alignment: Alignment.centerLeft,
            child: const ColoredBox(color: AppColors.accent),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Netflix-style secondary action button — icon over label, translucent fill.
// ─────────────────────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final fg = active ? AppColors.accent : AppColors.textPrimary;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 48,
        decoration: BoxDecoration(
          color: active ? AppColors.accentSoft : const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? AppColors.accent : AppColors.hairline,
            width: active ? 1 : 0.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: fg, size: 19),
            const SizedBox(width: 8),
            Text(
              label,
              style: AppText.caption.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status badge pill (mirrors Sozo Read's _StatusBadge)
// ─────────────────────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final MediaStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      MediaStatus.ongoing => const Color(0xFF30D158),   // green
      MediaStatus.completed => AppColors.accent,
      MediaStatus.hiatus => const Color(0xFFFF9F0A),    // amber
      MediaStatus.cancelled => AppColors.textTertiary,
      MediaStatus.unknown => AppColors.textTertiary,
    };
    final label = switch (status) {
      MediaStatus.ongoing => 'ONGOING',
      MediaStatus.completed => 'COMPLETED',
      MediaStatus.hiatus => 'HIATUS',
      MediaStatus.cancelled => 'CANCELLED',
      MediaStatus.unknown => 'UNKNOWN',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
