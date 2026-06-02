import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/di/injector.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../auth/auth_screens.dart';
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

  // Outer scroll position (the hero/header viewport). We listen to THIS instead
  // of a NotificationListener: the listener also fires for the inner TabBarView
  // lists (whose pixels start at 0), which flipped the title back OFF as soon as
  // you scrolled deeper into the episode list. NestedScrollView.controller drives
  // the OUTER viewport only, so its offset stays past the threshold once the hero
  // has collapsed — the title stays visible no matter how far the body scrolls.
  late final ScrollController _scrollController = ScrollController()
    ..addListener(_onScroll);

  late final TabController _tabController = TabController(
    length: 4,
    vsync: this,
  );

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
    _trailerFuture =
        sl<TrailerService>().youtubeId(
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
    _scrollController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // ── Scroll-driven app-bar title fade. PRESERVED EFFECT — reads the outer
  // NestedScrollView offset (Sozo Read's pattern). The title fades in as the
  // hero scrolls past and STAYS in while the body scrolls. ──────────────────
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final shouldShow =
        _scrollController.offset > (_expandedHeight - kToolbarHeight - 24);
    if (shouldShow != _showAppBarTitle) {
      setState(() => _showAppBarTitle = shouldShow);
    }
  }

  // ── The 5-icon action row wiring ──────────────────────────────────────────

  Future<void> _toggleMyList() async {
    if (!requireLogin(context, action: 'add to My List')) return;
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

    // Fresh play: prefer a saved per-title sub/dub choice, else the global
    // default category, else fall back to the incoming category. Constrain to
    // what's actually offered so single-category titles are a harmless no-op.
    final preferred =
        sl<TitlePrefsStore>().category(widget.item.sourceId, widget.item.url) ??
        sl<PlaybackPrefs>().defaultCategory;
    final launchCategory = availableCategories.contains(preferred)
        ? preferred
        : category;

    Navigator.of(context).push(
      MaterialPageRoute(
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
          category: launchCategory,
          availableCategories: availableCategories,
        ),
      ),
    );
  }

  /// Push the in-app trailer player for a resolved YouTube id.
  void _openTrailer(String videoId) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => TrailerScreen(videoId: videoId)));
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

  // ── Downloads ─────────────────────────────────────────────────────────────

  /// The main Download button. A movie / single episode goes straight to the
  /// server picker (CloudStream-style); a multi-episode season opens the
  /// quality + range batch sheet.
  Future<void> _openDownloadSheet({
    required MediaDetail detail,
    required List<Episode> episodes,
    required String category,
  }) async {
    if (episodes.isEmpty) {
      _snack('No episodes to download');
      return;
    }
    if (episodes.length == 1) {
      await _pickSourceAndDownload(episodes.first, detail, category);
      return;
    }
    final res = await showModalBottomSheet<({String quality, List<Episode> episodes})>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DownloadSheet(episodes: episodes, title: detail.title),
    );
    if (res == null || !mounted) return;
    _startDownload(detail, category, res.quality, res.episodes);
  }

  /// Per-episode / movie download → resolve sources, let the user pick a
  /// server/mirror, then download that exact url + headers.
  Future<void> _downloadSingle(
    Episode ep,
    MediaDetail detail,
    String category,
  ) => _pickSourceAndDownload(ep, detail, category);

  Future<void> _pickSourceAndDownload(
    Episode ep,
    MediaDetail detail,
    String category,
  ) async {
    final item = widget.item;
    final chosen = await showModalBottomSheet<VideoSource>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SourcePickerSheet(
        title: ep.title.trim().isNotEmpty ? ep.title : detail.title,
        resolve: () =>
            sl<SourceRepository>().sources(ep.url, sourceId: item.sourceId),
      ),
    );
    if (chosen == null || !mounted) return;
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
        source: chosen,
        qualityLabel: chosen.quality ?? 'auto',
        nowMs: DateTime.now().millisecondsSinceEpoch,
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
      ),
    );
    _snack(
      episodes.length == 1
          ? 'Added to downloads'
          : 'Downloading ${episodes.length} episodes',
    );
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
    BuildContext context,
    DetailState state,
    MediaDetail detail,
  ) {
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
        ? (seasonSet.contains(selectedSeason)
              ? selectedSeason
              : seasonSet.first)
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
    final downloadLabel = _downloadLabel(
      seasonEps,
      hasMultipleSeasons,
      currentSeason,
    );

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

    return NestedScrollView(
      controller: _scrollController,
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
                onTapFullscreen: _trailerId != null
                    ? () => _openTrailer(_trailerId!)
                    : null,
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
                      style: AppText.body.copyWith(
                        color: AppColors.textSecondary,
                      ),
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
                  onPressed: () => _openDownloadSheet(
                    detail: detail,
                    episodes: seasonEps,
                    category: category,
                  ),
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
                  icon: _inMyList ? Icons.check_rounded : Icons.add_rounded,
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
              unselectedLabelStyle: AppText.headline.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
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
            onDownload: (ep) => _downloadSingle(ep, detail, category),
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
        // Gradients render OVER the video for title readability.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.topScrim),
          ),
        ),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: AppColors.scrim),
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
                const Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.black,
                  size: 26,
                ),
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
              const Icon(
                Icons.file_download_outlined,
                color: Colors.white,
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(label, style: AppText.button.copyWith(color: Colors.white)),
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
  const _Description({required this.text, required this.onReadMore});

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
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // No divider line under the bar — just the left-aligned tabs (Sozo Read).
    return Material(color: AppColors.bg, elevation: 0, child: tabBar);
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) =>
      tabBar != oldDelegate.tabBar;
}

// ─────────────────────────────────────────────────────────────────────────────
// Episodes tab — season selector (multi-season) + rich episode rows. PRESERVES
// season filtering and _openPlayer. Sub/Dub selection now lives in the player.
// ─────────────────────────────────────────────────────────────────────────────

class _EpisodesTab extends StatefulWidget {
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

  /// Per-episode download icon → opens the download sheet for that episode.
  final void Function(Episode ep) onDownload;

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

  ({bool watched, bool inProgress, bool resume, double fraction}) _stateFor(
    ResumeStore store,
    Episode ep,
    int fullIndex,
  ) {
    final mark = store.get(widget.sourceId, ep.id);
    final inProgress =
        mark != null && !mark.finished && mark.duration > Duration.zero;
    final watched = mark != null && mark.finished;
    final resume =
        widget.hasAnyMark && fullIndex == widget.resumeIndex(widget.eps);
    final fraction = inProgress
        ? (mark.position.inMilliseconds / mark.duration.inMilliseconds)
              .clamp(0.0, 1.0)
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
            onInfo: widget.onInfo,
            grid: _grid,
            onToggleView: () => setState(() => _grid = !_grid),
            onJump: showRanges ? _jump : null,
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
        final displayTitle =
            widget.hasMultipleSeasons ? cleanTitle(ep.title) : ep.title;
        return RepaintBoundary(
          child: _EpisodeRow(
            ep: ep,
            epNum: epNum,
            displayTitle: displayTitle,
            coverUrl: widget.coverUrl,
            coverHeaders: widget.coverHeaders,
            isWatched: st.watched,
            isInProgress: st.inProgress,
            isResume: st.resume,
            fraction: st.fraction,
            onTap: () => widget.onOpen(fullIndex),
            onDownload: () => widget.onDownload(ep),
            sourceId: widget.sourceId,
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
    required this.onInfo,
    required this.grid,
    required this.onToggleView,
    this.onJump,
  });

  final bool hasMultipleSeasons;
  final List<int> seasons;
  final int currentSeason;
  final ValueChanged<int> onSelectSeason;
  final VoidCallback onInfo;

  /// Whether the grid view is active (toggles the view icon).
  final bool grid;
  final VoidCallback onToggleView;

  /// Jump-to-episode; null hides the button (short seasons don't need it).
  final VoidCallback? onJump;

  Widget _circle(IconData icon, VoidCallback onTap) => Material(
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
                  : Text('Episodes', style: AppText.headline),
            ),
          ),
          // Right: jump-to-episode (long seasons) · list/grid toggle · ⓘ info.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onJump != null) ...[
                _circle(Icons.search_rounded, onJump!),
                const SizedBox(width: 8),
              ],
              _circle(
                grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                onToggleView,
              ),
              const SizedBox(width: 8),
              _circle(Icons.info_outline_rounded, onInfo),
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
                          const Icon(
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
  });

  final int number;
  final bool isWatched;
  final bool isInProgress;
  final bool isResume;
  final bool isFiller;
  final bool highlight;
  final double fraction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = isResume
        ? AppColors.accent
        : (isWatched ? AppColors.surface : AppColors.surface2);
    final fg = isResume
        ? Colors.white
        : (isWatched ? AppColors.textTertiary : AppColors.textPrimary);
    final side = highlight
        ? const BorderSide(color: AppColors.accent, width: 2)
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
    required this.sourceId,
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
  final String sourceId;

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

    final heading = displayTitle.isNotEmpty
        ? '$epNum. $displayTitle'
        : 'Episode $epNum';

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
                                    color: AppColors.surface2,
                                  ),
                                  errorWidget: (c, u, e) => const ColoredBox(
                                    color: AppColors.surface2,
                                  ),
                                )
                              : const ColoredBox(color: AppColors.surface2),
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
                      if (subline != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subline,
                          style: AppText.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                      if (isResume || ep.filler) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            if (isResume) const TagBadge(text: 'CONTINUE'),
                            if (isResume && ep.filler) const SizedBox(width: 6),
                            if (ep.filler)
                              const TagBadge(
                                text: 'FILLER',
                                color: AppColors.textTertiary,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Per-episode download icon, reflecting download state.
                _EpisodeDownloadIcon(
                  sourceId: sourceId,
                  episodeId: ep.id,
                  onTap: onDownload,
                ),
              ],
            ),
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
    required this.episodeId,
    required this.onTap,
  });

  final String sourceId;
  final String episodeId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final manager = sl<DownloadManager>();
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final rec = manager.recordFor(sourceId, episodeId);
        return _glyph(rec?.status, rec?.progress ?? 0);
      },
    );
  }

  Widget _glyph(DownloadStatus? status, double progress) {
    final child = switch (status) {
      DownloadStatus.done => const Icon(
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
      DownloadStatus.failed => const Icon(
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
    return IconButton(
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      splashRadius: 22,
      icon: child,
    );
  }
}

// Server/mirror picker (CloudStream-style) — resolves the episode's sources
// and lists them so the user downloads a specific, real link. Returns the
// chosen VideoSource via pop. HLS sources are shown disabled (phase 2).
class _SourcePickerSheet extends StatefulWidget {
  const _SourcePickerSheet({required this.title, required this.resolve});

  final String title;
  final Future<List<VideoSource>> Function() resolve;

  @override
  State<_SourcePickerSheet> createState() => _SourcePickerSheetState();
}

class _SourcePickerSheetState extends State<_SourcePickerSheet> {
  List<VideoSource>? _sources;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.resolve();
      if (mounted) setState(() => _sources = s);
    } catch (_) {
      if (mounted) setState(() => _error = "Couldn't load download options");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _isHls(VideoSource s) =>
      s.container == SourceContainer.hls ||
      (Uri.tryParse(s.url)?.path ?? s.url).toLowerCase().endsWith('.m3u8');

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.of(context).size.height * 0.6;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text('Download · choose server', style: AppText.title),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                widget.title,
                style: AppText.caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              )
            else if (_error != null || (_sources?.isEmpty ?? true))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  _error ?? 'No download sources found',
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _sources!.length,
                  itemBuilder: (context, i) => _row(_sources![i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(VideoSource s) {
    final hls = _isHls(s);
    final label = (s.label != null && s.label!.trim().isNotEmpty)
        ? s.label!.trim()
        : (s.quality ?? 'Source');
    final sub = [
      if (s.quality != null && s.quality!.isNotEmpty) s.quality!,
      hls ? 'HLS · not available offline yet' : 'Direct',
    ].join(' · ');
    return ListTile(
      enabled: !hls,
      contentPadding: const EdgeInsets.only(right: 8),
      leading: Icon(
        hls ? Icons.cloud_off_outlined : Icons.download_rounded,
        color: hls ? AppColors.textTertiary : AppColors.accent,
      ),
      title: Text(
        label,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(sub, style: AppText.caption),
      onTap: hls ? null : () => Navigator.pop(context, s),
    );
  }
}

// Download sheet — pick a quality, then a range (RangeSlider) covering all /
// a span / a single episode. Returns the chosen (quality, episodes) via pop.
class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({required this.episodes, required this.title});

  final List<Episode> episodes;
  final String title;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  static const List<String> _qualities = ['1080p', '720p', '480p', 'best'];
  String _quality = '1080p';
  late RangeValues _range;

  @override
  void initState() {
    super.initState();
    _range = RangeValues(1, widget.episodes.length.toDouble());
  }

  List<Episode> get _selected {
    if (widget.episodes.length == 1) return widget.episodes;
    return widget.episodes.sublist(_range.start.round() - 1, _range.end.round());
  }

  String _epLabel(int pos1) {
    final e = widget.episodes[pos1 - 1];
    return 'E${e.number?.toInt() ?? pos1}';
  }

  @override
  Widget build(BuildContext context) {
    final multi = widget.episodes.length > 1;
    final count = _selected.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(bottom: 14),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Download', style: AppText.title),
            const SizedBox(height: 4),
            Text(
              widget.title,
              style: AppText.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 18),
            Text('Quality', style: AppText.overline),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [for (final q in _qualities) _qualityChip(q)],
            ),
            if (multi) ...[
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Episodes', style: AppText.overline),
                  Text(
                    '${_epLabel(_range.start.round())} – '
                    '${_epLabel(_range.end.round())}  ($count)',
                    style: AppText.caption.copyWith(
                      color: AppColors.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              RangeSlider(
                values: _range,
                min: 1,
                max: widget.episodes.length.toDouble(),
                divisions: widget.episodes.length > 1
                    ? widget.episodes.length - 1
                    : 1,
                activeColor: AppColors.accent,
                inactiveColor: AppColors.surface2,
                labels: RangeLabels(
                  _epLabel(_range.start.round()),
                  _epLabel(_range.end.round()),
                ),
                onChanged: (v) => setState(
                  () => _range = RangeValues(
                    v.start.roundToDouble(),
                    v.end.roundToDouble(),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Material(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => Navigator.pop(
                  context,
                  (quality: _quality, episodes: _selected),
                ),
                child: SizedBox(
                  height: 50,
                  width: double.infinity,
                  child: Center(
                    child: Text(
                      multi
                          ? 'Download $count episode${count == 1 ? '' : 's'}'
                          : 'Download',
                      style: AppText.button.copyWith(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _qualityChip(String q) {
    final sel = q == _quality;
    return Material(
      color: sel ? AppColors.accent : AppColors.surface2,
      borderRadius: BorderRadius.circular(9),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _quality = q),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            q == 'best' ? 'Best' : q,
            style: AppText.caption.copyWith(
              color: sel ? Colors.white : AppColors.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppColors.hairline, width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.person_rounded,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      name,
                      style: AppText.caption.copyWith(
                        color: AppColors.textPrimary,
                      ),
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
        if (sourceName.isNotEmpty)
          _DetailRow(label: 'Source', value: sourceName),
        if (statusStr.isNotEmpty) _DetailRow(label: 'Status', value: statusStr),
        if ((year ?? '').isNotEmpty) _DetailRow(label: 'Year', value: year!),
        _DetailRow(label: 'Episodes', value: '$episodeCount'),
        if (studios.isNotEmpty)
          _DetailRow(label: 'Studio', value: studios.join(', ')),
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
