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

  // ── My List (per-title store) ─────────────────────────────────────────────
  final MyListStore _myList = sl<MyListStore>();
  late bool _inMyList = _myList.contains(widget.item);

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

  void _share(MediaDetail detail, String sourceName) {
    final text = sourceName.isNotEmpty
        ? '${detail.title} — on $sourceName'
        : detail.title;
    Clipboard.setData(ClipboardData(text: text));
    _snack('Copied to clipboard');
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

  /// Netflix-style download label for the FIRST episode of the current season,
  /// e.g. "Download S1:E1". Falls back to a plain "Download" when there are no
  /// episodes to reference. (No downloads yet — label only; the button snacks.)
  String _downloadLabel(
    List<Episode> seasonEps,
    bool hasMultipleSeasons,
    int currentSeason,
  ) {
    if (seasonEps.isEmpty) return 'Download';
    final first = seasonEps.first;
    final epNum = first.number?.toInt() ?? 1;
    if (hasMultipleSeasons) return 'Download S$currentSeason:E$epNum';
    return 'Download E$epNum';
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
    final selectedSeason = state.selectedSeason;
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

    // ── Status label (used by the meta line and Details tab) ────────────────
    final statusStr = statusLabel(detail.status);

    // ── Netflix-style meta line: "2010 · 10 Seasons · Completed" ────────────
    // Join only what we actually HAVE with " · " (no faked rating/HD/CC).
    // Seasons when multi-season, else episode count.
    final metaParts = <String>[];
    if ((detail.year ?? '').isNotEmpty) metaParts.add(detail.year!);
    if (hasMultipleSeasons) {
      metaParts.add('${seasonSet.length} Seasons');
    } else if (eps.isNotEmpty) {
      metaParts.add('${eps.length} Episode${eps.length == 1 ? '' : 's'}');
    }
    if (statusStr.isNotEmpty) metaParts.add(statusStr);
    final metaLine = metaParts.join('  ·  ');

    // ── Download button label: "Download S{season}:E{n}" when we can derive
    // the first episode of the current season, else a plain "Download". ──────
    final downloadLabel = _downloadLabel(seasonEps, hasMultipleSeasons, currentSeason);

    // ── Starring / Creators (Genres fallback) muted lines ───────────────────
    final starring = detail.cast.isNotEmpty
        ? detail.cast.take(3).join(', ')
        : null;
    final starringMore = detail.cast.length > 3;
    final creators = detail.studios.isNotEmpty
        ? detail.studios.join(', ')
        : null;
    // For anime (or anything without cast) surface Genres instead of an empty
    // Starring line — never show an empty label.
    final genresLine = (starring == null && detail.genres.isNotEmpty)
        ? detail.genres.take(4).join(', ')
        : null;

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

          // ── 2. Title + meta line (Netflix header) ──────────────────────────
          SliverToBoxAdapter(
            child: RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.title,
                      style: AppText.largeTitle.copyWith(fontSize: 28),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (metaLine.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        metaLine,
                        style: AppText.body
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

          // ── 3. White Play + gray Download buttons (full-width, stacked) ─────
          // (The hero banner autoplays the trailer; tap it for fullscreen.)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Column(
                children: [
                  _PlayButton(
                    label: buttonLabel,
                    onPressed: eps.isNotEmpty
                        ? () => _openPlayer(eps, resumeIdx, detail, category)
                        : null,
                  ),
                  const SizedBox(height: 10),
                  _DownloadButton(
                    label: downloadLabel,
                    onPressed: () => _snack('Downloads coming soon'),
                  ),
                ],
              ),
            ),
          ),

          // ── 4. Synopsis (clamped) + "Read more" → Details tab ───────────────
          if ((detail.description ?? '').isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                child: _Description(
                  text: detail.description!,
                  // "Read more" jumps to the Details tab (full synopsis) rather
                  // than expanding inline; the header stays clamped to 3 lines.
                  onReadMore: () => _tabController.animateTo(3),
                ),
              ),
            ),

          // ── 5. Starring / Creators / Genres muted lines ─────────────────────
          if (starring != null || creators != null || genresLine != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (starring != null)
                      _CreditLine(
                        label: 'Starring',
                        value: starring,
                        more: starringMore,
                        // Tapping the line (or its "… more") opens the Cast tab.
                        onMore: starringMore
                            ? () => _tabController.animateTo(1)
                            : null,
                      ),
                    if (genresLine != null)
                      _CreditLine(label: 'Genres', value: genresLine),
                    if (creators != null)
                      _CreditLine(label: 'Creators', value: creators),
                  ],
                ),
              ),
            ),

          // ── 6. Icon-over-label action row (My List / Trailer / Share / Web) ─
          // "Trailer" is a CloudStream-style result action (recloudstream's
          // result fragment exposes a Trailer button); it opens the fullscreen
          // TrailerScreen and only appears once a trailer id has resolved.
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 20, 8, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _IconAction(
                    icon: _inMyList
                        ? Icons.check_rounded
                        : Icons.add_rounded,
                    active: _inMyList,
                    label: 'My List',
                    tooltip: _inMyList ? 'In My List' : 'Add to My List',
                    onTap: _toggleMyList,
                  ),
                  _IconAction(
                    icon: Icons.ios_share_rounded,
                    label: 'Share',
                    tooltip: 'Share',
                    onTap: () => _share(detail, sourceName),
                  ),
                  _IconAction(
                    icon: Icons.public_rounded,
                    label: 'Web',
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
                // Hug the left edge: the first tab starts flush with the 16px
                // content gutter (title/synopsis), and labelPadding(right: 24)
                // spaces the tabs apart while keeping them left-anchored —
                // never centered/spread (matches Sozo Read).
                padding: const EdgeInsets.only(left: 16),
                labelPadding: const EdgeInsets.only(right: 24),
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.textSecondary,
                indicatorSize: TabBarIndicatorSize.label,
                indicator: const UnderlineTabIndicator(
                  borderSide: BorderSide(color: AppColors.accent, width: 2.5),
                  insets: EdgeInsets.symmetric(horizontal: 2),
                ),
                // Remove the full-width underline divider under the bar.
                dividerColor: Colors.transparent,
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
              onInfo: () => _tabController.animateTo(3),
              onDownload: () => _snack('Downloads coming soon'),
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
    // Mount the Video widget NOW (build renders it once _videoController != null),
    // so media_kit's video output/texture exists BEFORE we play. Otherwise libmpv
    // (esp. on iOS) can sit paused until a relayout/tap and the trailer never
    // auto-starts — that was the "have to tap the banner to start it" bug.
    if (mounted) setState(() {});

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
      // Open WITHOUT relying solely on open(play:) — some engines/platforms
      // don't honor the autoplay flag until the first user interaction. Open
      // paused, then explicitly play() the moment the media is loaded and the
      // widget is still mounted, so the trailer starts on its own with no touch.
      await player.open(Media(url), play: !widget.collapsed);
      if (!mounted) return;
      // Only autostart when the hero is on-screen (expanded). If the user has
      // already scrolled past by the time the URL resolved, stay paused — the
      // collapsed/expanded handler in didUpdateWidget will play it when they
      // scroll back up.
      if (!widget.collapsed) {
        await player.play();
      }
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
// Full-width WHITE Play button (black label) — Netflix-style. Rounded ~8.
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.play_arrow_rounded,
                    color: Colors.black, size: 26),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: AppText.button.copyWith(color: Colors.black),
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
// Full-width GRAY Download button (surface2, white label) — Netflix-style.
// Downloads aren't implemented yet, so it just snacks.
// ─────────────────────────────────────────────────────────────────────────────

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: SizedBox(
          height: 52,
          width: double.infinity,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.file_download_outlined,
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Muted credit line: "Starring: a, b, c… more" / "Creators: …" / "Genres: …".
// The label is slightly dimmer than the value, matching Netflix's hierarchy.
// ─────────────────────────────────────────────────────────────────────────────

class _CreditLine extends StatelessWidget {
  const _CreditLine({
    required this.label,
    required this.value,
    this.more = false,
    this.onMore,
  });

  final String label;
  final String value;

  /// When true, append a "… more" affordance. When [onMore] is also set, the
  /// whole line is tappable and jumps to the relevant tab (Cast).
  final bool more;

  /// Tapping the line (or its "… more") jumps to the related tab. Null = inert.
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final base = AppText.caption.copyWith(color: AppColors.textSecondary);
    final line = Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: base.copyWith(color: AppColors.textTertiary),
            ),
            TextSpan(text: value, style: base),
            if (more)
              TextSpan(
                text: '… more',
                style: base.copyWith(color: AppColors.textPrimary),
              ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
    if (onMore == null) return line;
    return GestureDetector(
      onTap: onMore,
      behavior: HitTestBehavior.opaque,
      child: line,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Description: synopsis clamped to 3 lines + a red "Read more" that opens the
// Details tab (which shows the full synopsis). No inline expand.
// ─────────────────────────────────────────────────────────────────────────────

class _Description extends StatelessWidget {
  const _Description({
    required this.text,
    required this.onReadMore,
  });

  final String text;

  /// Jumps to the Details tab (full synopsis) — no inline expansion.
  final VoidCallback onReadMore;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onReadMore,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: AppText.body,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Text(
            'Read more',
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
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;

  /// Small caption shown under the icon (Netflix-style icon-over-label).
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.textPrimary;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 34,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: color),
              const SizedBox(height: 6),
              Text(
                label,
                style: AppText.caption.copyWith(
                  color: active ? AppColors.accent : AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
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

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    // No divider line under the bar — just the left-aligned tabs (Sozo Read).
    return Material(
      color: AppColors.bg,
      elevation: 0,
      child: tabBar,
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
    required this.onInfo,
    required this.onDownload,
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

  /// Opens the small circular ⓘ button → jumps to the Details tab.
  final VoidCallback onInfo;

  /// Per-episode download icon (no downloads yet → snackbar).
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final store = sl<ResumeStore>();

    if (eps.isEmpty) {
      return const EmptyState(
        icon: Icons.video_library_outlined,
        message: 'No episodes available from this source',
      );
    }

    // Sub/Dub selection moved to the PLAYER. The Episodes tab always opens with
    // a single header row: a Netflix-style season dropdown + ⓘ info button for
    // multi-season titles, or a plain "Episodes" header for single-season ones.
    const headerCount = 1;

    // Netflix uses whitespace, not divider lines — generous vertical gaps
    // between episodes instead of hairlines.
    return ListView.builder(
      padding: const EdgeInsets.only(top: 6, bottom: 48),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: seasonEps.length + headerCount,
      itemBuilder: (context0, rawIndex) {
        // Header row: Netflix-style season dropdown + ⓘ (multi-season) or a
        // plain "Episodes" label (single-season).
        if (rawIndex == 0) {
          return _EpisodesHeader(
            hasMultipleSeasons: hasMultipleSeasons,
            seasons: seasonSet.toList()..sort(),
            currentSeason: currentSeason,
            onSelectSeason: onSelectSeason,
            onInfo: onInfo,
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
            onDownload: onDownload,
          ),
        );
      },
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
    required this.onInfo,
  });

  final bool hasMultipleSeasons;
  final List<int> seasons;
  final int currentSeason;
  final ValueChanged<int> onSelectSeason;
  final VoidCallback onInfo;

  Future<void> _openSheet(BuildContext context) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppColors.surface,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _SeasonSheet(
        seasons: seasons,
        currentSeason: currentSeason,
      ),
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
                  : Text('Episodes', style: AppText.headline),
            ),
          ),
          // Right: small circular ⓘ info button → jumps to the Details tab.
          Material(
            color: AppColors.surface2,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onInfo,
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(
                  Icons.info_outline_rounded,
                  color: AppColors.textPrimary,
                  size: 20,
                ),
              ),
            ),
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
                        horizontal: 20, vertical: 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Season $s',
                            style: AppText.body.copyWith(
                              color: selected
                                  ? AppColors.textPrimary
                                  : AppColors.textSecondary,
                              fontWeight:
                                  selected ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (selected)
                          const Icon(Icons.check_rounded,
                              color: AppColors.accent, size: 22),
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
    required this.onDownload,
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
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    final titleColor = isResume
        ? AppColors.accent
        : (isWatched ? AppColors.textSecondary : AppColors.textPrimary);

    final thumbUrl = (ep.thumbnail != null && ep.thumbnail!.isNotEmpty)
        ? ep.thumbnail!
        : coverUrl;

    // Air date as a muted detail line (our model has no per-episode synopsis or
    // runtime; show the date when present, omit otherwise — no invented data).
    final subline = (ep.date != null && ep.date!.trim().isNotEmpty)
        ? ep.date!.trim()
        : null;

    final heading =
        displayTitle.isNotEmpty ? '$epNum. $displayTitle' : 'Episode $epNum';

    return InkWell(
      onTap: onTap,
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
                                  placeholder: (c, u) => const ColoredBox(
                                      color: AppColors.surface2),
                                  errorWidget: (c, u, e) => const ColoredBox(
                                      color: AppColors.surface2),
                                )
                              : const ColoredBox(color: AppColors.surface2),
                          if (isWatched)
                            const DecoratedBox(
                              decoration:
                                  BoxDecoration(color: Color(0x73000000)),
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
                                child: Icon(Icons.play_arrow_rounded,
                                    color: Colors.white, size: 22),
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
                          fontWeight:
                              isResume ? FontWeight.w800 : FontWeight.w700,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subline != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subline,
                          style: AppText.caption
                              .copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                      if (isResume || ep.filler) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (isResume) const TagBadge(text: 'CONTINUE'),
                            if (isResume && ep.filler)
                              const SizedBox(width: 6),
                            if (ep.filler)
                              const TagBadge(
                                  text: 'FILLER',
                                  color: AppColors.textTertiary),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Per-episode download icon (no downloads yet → snackbar).
                IconButton(
                  onPressed: onDownload,
                  visualDensity: VisualDensity.compact,
                  splashRadius: 22,
                  icon: const Icon(
                    Icons.file_download_outlined,
                    color: AppColors.textPrimary,
                    size: 24,
                  ),
                ),
              ],
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
