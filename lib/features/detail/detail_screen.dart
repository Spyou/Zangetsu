import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

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
import '../../core/trailer/trailer_service.dart';
import '../../core/ui/badge.dart';
import '../../core/ui/brand_loader.dart';
import '../../core/ui/states.dart';
import '../player/player_screen.dart';
import '../trailer/trailer_screen.dart';
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
// _DetailView — StatefulWidget for the scroll-driven app-bar title fade and the
// four-tab layout (Episodes / Cast / Relations / Details). The scroll position
// and TabController are pure UI state and stay widget-level; everything
// data-related (detail / category / season / desc-expand) lives in DetailCubit
// and is consumed via BlocBuilder below.
// ─────────────────────────────────────────────────────────────────────────────

class _DetailView extends StatefulWidget {
  const _DetailView({required this.item});
  final MediaItem item;

  @override
  State<_DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends State<_DetailView>
    with SingleTickerProviderStateMixin {
  static const double _expandedHeight = 320;
  bool _showAppBarTitle = false;

  late final TabController _tabController =
      TabController(length: 4, vsync: this);

  // ── My List + Favorite (per-title stores) ────────────────────────────────
  final MyListStore _myList = sl<MyListStore>();
  final TitlePrefsStore _prefs = sl<TitlePrefsStore>();
  late bool _inMyList = _myList.contains(widget.item);
  late bool _isFavorite =
      _prefs.isFavorite(widget.item.sourceId, widget.item.url);

  // ── Trailer (metadata-API lookup) ─────────────────────────────────────────
  // Resolved lazily once per detail load and cached so the hero player doesn't
  // refetch on every rebuild. Yields a YouTube id or null; once it resolves the
  // hero swaps its static cover backdrop for an autoplaying, muted, looping
  // player (Netflix-style).
  Future<String?>? _trailerFuture;
  String? _trailerId;

  /// Kick off (once) the YouTube-id lookup for the resolved detail. When it
  /// completes with a non-null id, store it in [_trailerId] and rebuild so the
  /// hero can mount the trailer player.
  void _resolveTrailer(MediaDetail detail) {
    if (_trailerFuture != null) return;
    _trailerFuture = sl<TrailerService>().youtubeId(
      title: detail.title,
      englishTitle: detail.englishTitle,
      type: detail.type,
      year: detail.year,
    )..then((id) {
        if (!mounted) return;
        if (id != null && id.isNotEmpty && id != _trailerId) {
          setState(() => _trailerId = id);
        }
      });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ── Scroll-driven app-bar title fade. PRESERVED EFFECT — adapted to the
  // NestedScrollView outer viewport (Sozo Read's pattern). The title fades in
  // as the hero scrolls past. ─────────────────────────────────────────────
  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final shouldShow =
        n.metrics.pixels > (_expandedHeight - kToolbarHeight - 24);
    if (shouldShow != _showAppBarTitle) {
      setState(() => _showAppBarTitle = shouldShow);
    }
    return false;
  }

  // ── The 5-icon action row wiring ──────────────────────────────────────────

  Future<void> _toggleMyList() async {
    await _myList.toggle(widget.item);
    if (!mounted) return;
    setState(() => _inMyList = _myList.contains(widget.item));
  }

  Future<void> _toggleFavorite() async {
    final next =
        await _prefs.toggleFavorite(widget.item.sourceId, widget.item.url);
    if (!mounted) return;
    setState(() => _isFavorite = next);
  }

  void _share(MediaDetail detail, String sourceName) {
    final text = sourceName.isNotEmpty
        ? '${detail.title} — on $sourceName'
        : detail.title;
    Clipboard.setData(ClipboardData(text: text));
    _snack('Copied to clipboard');
  }

  /// ✕ — paired with the bookmark. Removes the title from My List when it's
  /// saved; otherwise a brief hint.
  Future<void> _removeFromMyList() async {
    if (!_inMyList) {
      _snack('Not in My List');
      return;
    }
    await _myList.toggle(widget.item); // toggle off
    if (!mounted) return;
    setState(() => _inMyList = _myList.contains(widget.item));
    _snack('Removed from My List');
  }

  /// Globe — open the source's web page in the system browser. Falls back to
  /// a snackbar when no usable URL can be derived.
  Future<void> _openSourceSite() async {
    final url = _sourceWebUrl();
    if (url == null) {
      _snack('No web page for this source');
      return;
    }
    final ok = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) _snack('Could not open the source site');
  }

  /// Best-effort web URL for the title. Prefers an absolute item URL; else
  /// the source's display name has no base here, so we surface the raw URL
  /// only when it already looks like a link.
  String? _sourceWebUrl() {
    final u = widget.item.url.trim();
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    return null;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: AppText.caption.copyWith(color: Colors.white)),
          backgroundColor: AppColors.surface2,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  // ── Cross-source player launch — PRESERVED EXACTLY ────────────────────────

  void _openPlayer(
    List<Episode> episodes,
    int index,
    MediaDetail detail,
    String category,
  ) {
    // Available sub/dub categories from the detail — lets the PLAYER offer the
    // Sub/Dub switch (the Detail no longer does). Empty/single → treated as a
    // single-category source by the player (no Version section).
    final available = <String>[
      if ((detail.subCount ?? 0) > 0) 'sub',
      if ((detail.dubCount ?? 0) > 0) 'dub',
    ];
    final availableCategories = available.isEmpty ? [category] : available;

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
        availableCategories: availableCategories,
      ),
    ));
  }

  /// Push the in-app trailer player for a resolved YouTube id.
  void _openTrailer(String videoId) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TrailerScreen(videoId: videoId),
    ));
  }

  /// Walk episodes and return the best resume target index. PRESERVED.
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

  Widget _buildBody(
      BuildContext context, DetailState state, MediaDetail detail) {
    final item = widget.item;
    final cubit = context.read<DetailCubit>();
    final category = state.category;
    final descExpanded = state.descExpanded;
    final selectedSeason = state.selectedSeason;
    final showSubDub = showSubDubFor(detail);
    final eps = detail.episodes;
    final store = sl<ResumeStore>();

    // Resume / play button logic. PRESERVED.
    final resumeIdx = _resumeIndex(eps);
    final hasAnyMark = eps.any((e) => store.get(item.sourceId, e.id) != null);
    final episodeNum = eps.isNotEmpty
        ? (eps[resumeIdx].number?.toInt() ?? resumeIdx + 1)
        : 1;
    final buttonLabel = hasAnyMark ? 'Continue E$episodeNum' : 'Play';

    // Cover / backdrop.
    final coverUrl = detail.cover ?? item.cover ?? '';
    final coverHeaders = detail.coverHeaders ?? item.coverHeaders;
    final hasCover = coverUrl.isNotEmpty;

    // Kick off the trailer lookup (once). When it resolves, _trailerId is set
    // and the hero swaps its static backdrop for the autoplaying trailer.
    _resolveTrailer(detail);

    // Season data. PRESERVED.
    final seasonSet = seasonsOf(eps);
    final hasMultipleSeasons = seasonSet.length > 1;
    final currentSeason = hasMultipleSeasons
        ? (seasonSet.contains(selectedSeason) ? selectedSeason : seasonSet.first)
        : 1;
    final seasonEps = hasMultipleSeasons
        ? eps.where((e) => parseSeason(e.title) == currentSeason).toList()
        : eps;

    // ── "RELEASING" status badge + "Total of X / Y" availability line ───────
    final statusStr = statusLabel(detail.status);
    // Available / total. When sub/dub counts exist (anime), the active track's
    // count is the "available" count and total is the larger of the two; else
    // fall back to the parsed episode count for both.
    final subN = detail.subCount ?? 0;
    final dubN = detail.dubCount ?? 0;
    final maxTrack = subN > dubN ? subN : dubN;
    final available = showSubDub
        ? (category == 'sub' ? subN : dubN)
        : eps.length;
    final total = showSubDub && maxTrack > 0 ? maxTrack : eps.length;

    // ── Title meta line: "2023 · Action / Horror · 1 Season" ────────────────
    final metaParts = <String>[];
    if ((detail.year ?? '').isNotEmpty) metaParts.add(detail.year!);
    if (detail.genres.isNotEmpty) metaParts.add(detail.genres.take(2).join(' / '));
    if (hasMultipleSeasons) {
      metaParts.add('${seasonSet.length} Seasons');
    } else if (eps.isNotEmpty) {
      metaParts.add('${eps.length} Episode${eps.length == 1 ? '' : 's'}');
    }
    final metaLine = metaParts.join('  ·  ');

    // Friendly provider name.
    final sourceName =
        sl<ProviderRegistry>().entryFor(item.sourceId)?.displayName ??
            item.sourceId;

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          // ── 1. Hero: backdrop + overlapping poster + status/total ──────────
          SliverAppBar(
            expandedHeight: _expandedHeight,
            pinned: true,
            backgroundColor: AppColors.bg,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            centerTitle: false,
            titleSpacing: 0,
            // PRESERVED EFFECT: title fades in once the hero scrolls past.
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
                child: _Hero(
                  coverUrl: coverUrl,
                  coverHeaders: coverHeaders,
                  hasCover: hasCover,
                  trailerId: _trailerId,
                  // Pause the trailer once the hero has scrolled past (reuses
                  // the same signal that fades in the app-bar title).
                  collapsed: _showAppBarTitle,
                  onTapFullscreen:
                      _trailerId != null ? () => _openTrailer(_trailerId!) : null,
                ),
              ),
            ),
          ),

          // ── 2. Status badge + "Total of X / Y" ─────────────────────────────
          SliverToBoxAdapter(
            child: RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Row(
                  children: [
                    if (statusStr.isNotEmpty)
                      _ReleaseBadge(label: statusStr.toUpperCase()),
                    if (statusStr.isNotEmpty) const SizedBox(width: 12),
                    Text(
                      'Total of $available / $total',
                      style: AppText.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── 3. Title + meta line ───────────────────────────────────────────
          SliverToBoxAdapter(
            child: RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.title,
                      style: AppText.largeTitle.copyWith(fontSize: 26),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (metaLine.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        metaLine,
                        style: AppText.caption
                            .copyWith(color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),

          // ── 4. Action row: red Play + square download ──────────────────────
          // (The hero banner now autoplays the trailer, so the standalone
          // "Trailer" button is gone — tap the banner for fullscreen.)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: _PlayButton(
                      label: buttonLabel,
                      onPressed: eps.isNotEmpty
                          ? () => _openPlayer(eps, resumeIdx, detail, category)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _DownloadButton(
                    onPressed: () => _snack('Downloads coming soon'),
                  ),
                ],
              ),
            ),
          ),

          // ── 5. Description + inline Read more ───────────────────────────────
          if ((detail.description ?? '').isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _Description(
                  text: detail.description!,
                  expanded: descExpanded,
                  onToggle: cubit.toggleDesc,
                ),
              ),
            ),

          // ── 6. Five-icon action row ─────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 18, 8, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _IconAction(
                    icon: _inMyList
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_outline_rounded,
                    active: _inMyList,
                    tooltip: 'My List',
                    onTap: _toggleMyList,
                  ),
                  _IconAction(
                    icon: _isFavorite
                        ? Icons.favorite_rounded
                        : Icons.favorite_outline_rounded,
                    active: _isFavorite,
                    tooltip: 'Favorite',
                    onTap: _toggleFavorite,
                  ),
                  _IconAction(
                    icon: Icons.ios_share_rounded,
                    tooltip: 'Share',
                    onTap: () => _share(detail, sourceName),
                  ),
                  _IconAction(
                    icon: Icons.close_rounded,
                    tooltip: 'Remove from My List',
                    onTap: _removeFromMyList,
                  ),
                  _IconAction(
                    icon: Icons.public_rounded,
                    tooltip: 'Open source site',
                    onTap: _openSourceSite,
                  ),
                ],
              ),
            ),
          ),

          // ── 7. Pinned tab bar ───────────────────────────────────────────────
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabBarDelegate(
              TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorSize: TabBarIndicatorSize.label,
                indicator: const UnderlineTabIndicator(
                  borderSide: BorderSide(color: AppColors.accent, width: 2.5),
                  insets: EdgeInsets.symmetric(horizontal: 2),
                ),
                dividerHeight: 0,
                splashFactory: NoSplash.splashFactory,
                overlayColor: WidgetStateProperty.all(Colors.transparent),
                labelStyle: AppText.headline.copyWith(fontSize: 15),
                unselectedLabelStyle:
                    AppText.headline.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
                tabs: const [
                  Tab(text: 'Episodes'),
                  Tab(text: 'Cast'),
                  Tab(text: 'Relations'),
                  Tab(text: 'Details'),
                ],
              ),
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabController,
          children: [
            // ── Episodes ──────────────────────────────────────────────────────
            _EpisodesTab(
              eps: eps,
              seasonEps: seasonEps,
              hasMultipleSeasons: hasMultipleSeasons,
              seasonSet: seasonSet,
              currentSeason: currentSeason,
              onSelectSeason: cubit.selectSeason,
              coverUrl: coverUrl,
              coverHeaders: coverHeaders,
              sourceId: item.sourceId,
              resumeIndex: _resumeIndex,
              hasAnyMark: hasAnyMark,
              onOpen: (fullIndex) =>
                  _openPlayer(eps, fullIndex, detail, category),
            ),
            // ── Cast ────────────────────────────────────────────────────────────
            _CastTab(cast: detail.cast),
            // ── Relations (no data) ──────────────────────────────────────────────
            const _RelationsTab(),
            // ── Details ──────────────────────────────────────────────────────────
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Hero — full-width backdrop with a portrait poster overlapping the bottom-right
// and a back arrow over the top-left.
// ─────────────────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  const _Hero({
    required this.coverUrl,
    required this.coverHeaders,
    required this.hasCover,
    this.trailerId,
    this.collapsed = false,
    this.onTapFullscreen,
  });

  final String coverUrl;
  final Map<String, String>? coverHeaders;
  final bool hasCover;

  /// Resolved YouTube id, or null while still loading / when none exists.
  final String? trailerId;

  /// True once the hero has scrolled past — the trailer pauses while collapsed.
  final bool collapsed;

  /// Opens the fullscreen trailer when the banner is tapped. Null disables it.
  final VoidCallback? onTapFullscreen;

  /// The static cover backdrop — used as the base layer when there's no
  /// trailer, and as the placeholder/fallback underneath the player.
  Widget _coverBackdrop() {
    return hasCover
        ? CachedNetworkImage(
            imageUrl: coverUrl,
            httpHeaders: coverHeaders,
            fit: BoxFit.cover,
            memCacheWidth: 800,
            placeholder: (c, u) => const ColoredBox(color: AppColors.surface2),
            errorWidget: (c, u, e) =>
                const ColoredBox(color: AppColors.surface2),
          )
        : const ColoredBox(color: AppColors.surface2);
  }

  @override
  Widget build(BuildContext context) {
    final id = trailerId;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Backdrop: autoplaying trailer once an id resolves, else the cover
        // image. The cover image always sits underneath as placeholder/fallback
        // so there's never a blank/black flash.
        (id != null && id.isNotEmpty)
            ? _HeroTrailer(
                videoId: id,
                collapsed: collapsed,
                onTapFullscreen: onTapFullscreen,
                placeholder: _coverBackdrop(),
              )
            : _coverBackdrop(),
        // Gradients render OVER the video for title/poster readability.
        const IgnorePointer(
          child: DecoratedBox(decoration: BoxDecoration(gradient: AppColors.topScrim)),
        ),
        const IgnorePointer(
          child: DecoratedBox(decoration: BoxDecoration(gradient: AppColors.scrim)),
        ),
        // Overlapping portrait poster, bottom-right.
        Positioned(
          right: 16,
          bottom: 14,
          child: SizedBox(
            height: 132,
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 18,
                      offset: Offset(0, 8),
                    ),
                  ],
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                    width: 0.5,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: hasCover
                      ? CachedNetworkImage(
                          imageUrl: coverUrl,
                          httpHeaders: coverHeaders,
                          fit: BoxFit.cover,
                          memCacheWidth: 240,
                          placeholder: (c, u) =>
                              const ColoredBox(color: AppColors.surface2),
                          errorWidget: (c, u, e) =>
                              const ColoredBox(color: AppColors.surface2),
                        )
                      : const ColoredBox(color: AppColors.surface2),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _HeroTrailer — the autoplaying, muted, looping trailer that becomes the hero
// backdrop once a YouTube id resolves (Netflix-style). The trailer is a DIRECT
// muxed stream (extracted by youtube_explode_dart) played natively via
// media_kit — NO iframe, NO YouTube chrome (no related-videos / endscreen /
// branding). The static cover image stays visible underneath until the first
// frame is painted, so there's never a blank/black flash; if extraction or
// playback fails we keep showing the cover.
//
// • Muted + autoplay + loops the single media + cover-fit (BoxFit.cover).
// • A bottom-left mute toggle (default muted); the choice survives pause/resume.
// • Pauses when [collapsed] (scrolled past) and on dispose; the Player is
//   created only once a stream URL resolves and is disposed in dispose().
// • Tapping the banner (outside the mute button) opens the fullscreen trailer.
// ─────────────────────────────────────────────────────────────────────────────

class _HeroTrailer extends StatefulWidget {
  const _HeroTrailer({
    required this.videoId,
    required this.collapsed,
    required this.placeholder,
    this.onTapFullscreen,
  });

  final String videoId;
  final bool collapsed;
  final Widget placeholder;
  final VoidCallback? onTapFullscreen;

  @override
  State<_HeroTrailer> createState() => _HeroTrailerState();
}

class _HeroTrailerState extends State<_HeroTrailer> {
  // Created lazily once a stream URL resolves — never before, so a failed
  // extraction never mounts an empty/black player.
  Player? _player;
  VideoController? _videoController;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;

  // Cross-fade the player in once it's actually playing so the cover never
  // blanks.
  bool _ready = false;
  // Extraction or playback failed → stay on the static cover.
  bool _errored = false;
  // Mute state — default muted; preserved across pause/resume.
  bool _muted = true;

  @override
  void initState() {
    super.initState();
    _resolveAndOpen();
  }

  /// Extract a light muxed stream for the banner and start it muted + looping.
  /// On any failure we flip [_errored] and the cover stays as the backdrop.
  Future<void> _resolveAndOpen() async {
    final url = await sl<TrailerService>().streamUrl(widget.videoId, low: true);
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      setState(() => _errored = true);
      return;
    }
    final player = Player();
    final controller = VideoController(player);
    _player = player;
    _videoController = controller;

    await player.setVolume(_muted ? 0 : 100);
    // Loop the single trailer media (Netflix-style).
    await player.setPlaylistMode(PlaylistMode.single);

    // Reveal the player on the first "playing" event so we cross-fade in
    // rather than showing a black first frame.
    _playingSub = player.stream.playing.listen((playing) {
      if (!mounted) return;
      if (playing && !_ready) setState(() => _ready = true);
    });
    // Belt-and-braces loop: also restart on completion (covers engines where
    // PlaylistMode.single doesn't auto-restart a single media).
    _completedSub = player.stream.completed.listen((done) {
      if (done && mounted && !widget.collapsed) {
        _player?.seek(Duration.zero);
        _player?.play();
      }
    });

    try {
      await player.open(Media(url), play: !widget.collapsed);
    } catch (_) {
      if (!mounted) return;
      setState(() => _errored = true);
    }
  }

  @override
  void didUpdateWidget(covariant _HeroTrailer old) {
    super.didUpdateWidget(old);
    // Re-resolve from scratch if the id changes (different title).
    if (old.videoId != widget.videoId) {
      _disposePlayer();
      _ready = false;
      _errored = false;
      _resolveAndOpen();
    }
    // Pause when scrolled past the hero; resume when it's expanded again.
    if (widget.collapsed != old.collapsed && !_errored) {
      if (widget.collapsed) {
        _player?.pause();
      } else {
        _player?.play();
      }
    }
  }

  Future<void> _toggleMute() async {
    final player = _player;
    if (player == null) return;
    final next = !_muted;
    await player.setVolume(next ? 0 : 100);
    if (!mounted) return;
    setState(() => _muted = next);
  }

  void _disposePlayer() {
    _playingSub?.cancel();
    _completedSub?.cancel();
    _playingSub = null;
    _completedSub = null;
    _videoController = null;
    _player?.dispose();
    _player = null;
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _videoController;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Cover image underneath as placeholder + permanent fallback.
        widget.placeholder,
        // The native player, cover-fitted to fill the hero. Faded in once it's
        // actually playing; hidden entirely if extraction/playback errored.
        if (controller != null && !_errored)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _ready ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOut,
                child: Video(
                  controller: controller,
                  controls: NoVideoControls,
                  fit: BoxFit.cover,
                  fill: Colors.transparent,
                ),
              ),
            ),
          ),
        // Tap anywhere on the banner (outside the mute button) → fullscreen.
        if (widget.onTapFullscreen != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: widget.onTapFullscreen,
            ),
          ),
        // Mute toggle — bottom-left, clear of the bottom-right poster and the
        // top-left back arrow. Only shown once the player is ready (mute is
        // meaningless before that).
        if (_ready && !_errored)
          Positioned(
            left: 14,
            bottom: 14,
            child: _MuteButton(muted: _muted, onTap: _toggleMute),
          ),
      ],
    );
  }
}

// Small translucent circular mute/unmute toggle for the hero trailer.
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onTap});
  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x66000000),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// "RELEASING" / status badge — small red pill.
// ─────────────────────────────────────────────────────────────────────────────

class _ReleaseBadge extends StatelessWidget {
  const _ReleaseBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: AppText.overline.copyWith(
          color: Colors.white,
          fontSize: 11,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Wide red Play button + label.
// ─────────────────────────────────────────────────────────────────────────────

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Material(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: SizedBox(
            height: 52,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 24),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: AppText.button.copyWith(color: Colors.white),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Square red download button (placeholder action).
// ─────────────────────────────────────────────────────────────────────────────

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: const SizedBox(
          width: 52,
          height: 52,
          child: Icon(Icons.file_download_outlined,
              color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Description: 3 lines + inline red "Read more" that expands.
// ─────────────────────────────────────────────────────────────────────────────

class _Description extends StatelessWidget {
  const _Description({
    required this.text,
    required this.expanded,
    required this.onToggle,
  });

  final String text;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: Text(
              text,
              style: AppText.body,
              maxLines: expanded ? null : 3,
              overflow:
                  expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            expanded ? 'Read less' : 'Read more',
            style: AppText.caption.copyWith(
              color: AppColors.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// One of the 5 outlined icon actions.
// ─────────────────────────────────────────────────────────────────────────────

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 26,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            icon,
            size: 24,
            color: active ? AppColors.accent : AppColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pinned tab-bar delegate.
// ─────────────────────────────────────────────────────────────────────────────

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate(this.tabBar);
  final TabBar tabBar;

  // +1 for the hairline divider rendered under the tab bar.
  @override
  double get minExtent => tabBar.preferredSize.height + 1;
  @override
  double get maxExtent => tabBar.preferredSize.height + 1;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      color: AppColors.bg,
      elevation: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          tabBar,
          const Divider(color: AppColors.hairline, height: 1, thickness: 1),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) =>
      tabBar != oldDelegate.tabBar;
}

// ─────────────────────────────────────────────────────────────────────────────
// Episodes tab — season selector (multi-season) + rich episode rows. PRESERVES
// season filtering and _openPlayer. Sub/Dub selection now lives in the player.
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodesTab extends StatelessWidget {
  const _EpisodesTab({
    required this.eps,
    required this.seasonEps,
    required this.hasMultipleSeasons,
    required this.seasonSet,
    required this.currentSeason,
    required this.onSelectSeason,
    required this.coverUrl,
    required this.coverHeaders,
    required this.sourceId,
    required this.resumeIndex,
    required this.hasAnyMark,
    required this.onOpen,
  });

  final List<Episode> eps;
  final List<Episode> seasonEps;
  final bool hasMultipleSeasons;
  final Set<int> seasonSet;
  final int currentSeason;
  final ValueChanged<int> onSelectSeason;
  final String coverUrl;
  final Map<String, String>? coverHeaders;
  final String sourceId;
  final int Function(List<Episode>) resumeIndex;
  final bool hasAnyMark;
  final void Function(int fullIndex) onOpen;

  @override
  Widget build(BuildContext context) {
    final store = sl<ResumeStore>();

    if (eps.isEmpty) {
      return const EmptyState(
        icon: Icons.video_library_outlined,
        message: 'No episodes available from this source',
      );
    }

    // Sub/Dub selection moved to the PLAYER — the only optional header row left
    // is the season selector (multi-season titles).
    final headerCount = hasMultipleSeasons ? 1 : 0;

    return ListView.separated(
      padding: const EdgeInsets.only(top: 8, bottom: 40),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: seasonEps.length + headerCount,
      separatorBuilder: (context0, i) {
        if (i < headerCount) return const SizedBox.shrink();
        return const Divider(
          height: 1,
          thickness: 0,
          color: AppColors.hairline,
          indent: 16,
          endIndent: 16,
        );
      },
      itemBuilder: (context0, rawIndex) {
        // Header row: season selector (multi-season only).
        if (hasMultipleSeasons && rawIndex == 0) {
          return _SeasonSelector(
            seasons: seasonSet.toList()..sort(),
            selectedSeason: currentSeason,
            onSelectSeason: onSelectSeason,
          );
        }

        final i = rawIndex - headerCount;
        final ep = seasonEps[i];
        final fullIndex = eps.indexOf(ep);
        final mark = store.get(sourceId, ep.id);
        final isInProgress =
            mark != null && !mark.finished && mark.duration > Duration.zero;
        final isWatched = mark != null && mark.finished;
        final isResume = hasAnyMark && fullIndex == resumeIndex(eps);
        final fraction = isInProgress
            ? (mark.position.inMilliseconds / mark.duration.inMilliseconds)
                .clamp(0.0, 1.0)
            : 0.0;

        final epNum = ep.number?.toInt() ?? i + 1;
        final rawTitle = ep.title;
        final displayTitle =
            hasMultipleSeasons ? cleanTitle(rawTitle) : rawTitle;

        return RepaintBoundary(
          child: _EpisodeRow(
            ep: ep,
            epNum: epNum,
            displayTitle: displayTitle,
            coverUrl: coverUrl,
            coverHeaders: coverHeaders,
            isWatched: isWatched,
            isInProgress: isInProgress,
            isResume: isResume,
            fraction: fraction,
            onTap: () => onOpen(fullIndex),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Season selector — horizontal pill chips.
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
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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
// Rich episode row — "N. Title", duration/date, 16:9 thumbnail, synopsis line.
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
  });

  final Episode ep;
  final int epNum;
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

    final thumbUrl = (ep.thumbnail != null && ep.thumbnail!.isNotEmpty)
        ? ep.thumbnail!
        : coverUrl;

    // Air date as a muted detail line (our model has no per-episode synopsis;
    // show date when present, omit otherwise — no invented data).
    final subline = (ep.date != null && ep.date!.trim().isNotEmpty)
        ? ep.date!.trim()
        : null;

    final heading = displayTitle.isNotEmpty ? '$epNum. $displayTitle' : 'Episode $epNum';

    return InkWell(
      onTap: onTap,
      splashColor: AppColors.accentSoft,
      highlightColor: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Compact 16:9 thumbnail on the left (Netflix/CloudStream row).
            SizedBox(
              width: 128,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
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
                                  const ColoredBox(color: AppColors.surface2),
                              errorWidget: (c, u, e) =>
                                  const ColoredBox(color: AppColors.surface2),
                            )
                          : const ColoredBox(color: AppColors.surface2),
                      if (isWatched)
                        const DecoratedBox(
                          decoration: BoxDecoration(color: Color(0x73000000)),
                          child: SizedBox.expand(),
                        ),
                      const Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color(0x66000000),
                            shape: BoxShape.circle,
                          ),
                          child: Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.play_arrow_rounded,
                                color: Colors.white, size: 20),
                          ),
                        ),
                      ),
                      if (isWatched)
                        const Positioned(
                          top: 4,
                          right: 4,
                          child: Icon(Icons.check_circle,
                              color: Colors.white, size: 16),
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
            const SizedBox(width: 12),
            // Number · title · badges · sub-line.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          heading,
                          style: AppText.body.copyWith(
                            color: titleColor,
                            fontWeight:
                                isResume ? FontWeight.w800 : FontWeight.w700,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isResume) ...[
                        const SizedBox(width: 6),
                        const TagBadge(text: 'CONTINUE'),
                      ],
                      if (ep.filler) ...[
                        const SizedBox(width: 6),
                        const TagBadge(
                            text: 'FILLER', color: AppColors.textTertiary),
                      ],
                    ],
                  ),
                  if (subline != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subline,
                      style: AppText.caption
                          .copyWith(color: AppColors.textTertiary),
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

class _ThumbnailProgressBar extends StatelessWidget {
  const _ThumbnailProgressBar({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 4,
      child: Stack(
        children: [
          const ColoredBox(color: Color(0x80000000), child: SizedBox.expand()),
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
// Cast tab — chips of cast members; graceful empty state.
// ─────────────────────────────────────────────────────────────────────────────

class _CastTab extends StatelessWidget {
  const _CastTab({required this.cast});
  final List<String> cast;

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) {
      return const EmptyState(
        icon: Icons.people_outline_rounded,
        message: 'No cast information',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 10,
          children: [
            for (final name in cast)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.hairline, width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.person_rounded,
                        size: 16, color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Text(
                      name,
                      style: AppText.caption
                          .copyWith(color: AppColors.textPrimary),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Relations tab — no relations data in our model; tasteful empty state.
// ─────────────────────────────────────────────────────────────────────────────

class _RelationsTab extends StatelessWidget {
  const _RelationsTab();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.account_tree_outlined,
      message: 'No related titles',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Details tab — source / status / genres / studios / episode count / synopsis.
// ─────────────────────────────────────────────────────────────────────────────

class _DetailsTab extends StatelessWidget {
  const _DetailsTab({
    required this.sourceName,
    required this.statusStr,
    required this.genres,
    required this.studios,
    required this.episodeCount,
    required this.year,
    required this.description,
  });

  final String sourceName;
  final String statusStr;
  final List<String> genres;
  final List<String> studios;
  final int episodeCount;
  final String? year;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final desc = description ?? '';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      children: [
        if (sourceName.isNotEmpty) _DetailRow(label: 'Source', value: sourceName),
        if (statusStr.isNotEmpty) _DetailRow(label: 'Status', value: statusStr),
        if ((year ?? '').isNotEmpty) _DetailRow(label: 'Year', value: year!),
        _DetailRow(label: 'Episodes', value: '$episodeCount'),
        if (studios.isNotEmpty)
          _DetailRow(label: 'Studio', value: studios.join(', ')),
        if (genres.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('Genres',
              style: AppText.caption.copyWith(color: AppColors.textTertiary)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: genres
                .map((g) =>
                    TagBadge(text: g, color: AppColors.textSecondary))
                .toList(),
          ),
        ],
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Synopsis',
              style: AppText.caption.copyWith(color: AppColors.textTertiary)),
          const SizedBox(height: 8),
          Text(desc, style: AppText.body),
        ],
      ],
    );
  }
}

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
