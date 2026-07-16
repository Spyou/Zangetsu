import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/notify/cs_notify.dart';
import '../../core/notify/notification_service.dart';
import '../../core/notify/subscription_store.dart';
import '../../core/share/share_link.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_detail.dart';
import 'episode_filter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_extras.dart';
import '../../core/models/person.dart';
import '../home/search_screen.dart';
import '../people/person_page.dart';
import '../../core/models/video_source.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/playback/my_list.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/trailer/trailer_service.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/aniyomi/aniyomi_image_provider.dart';
import '../../core/ui/badge.dart';
import '../../core/ui/states.dart';
import '../player/player_screen.dart';
import '../player/tv_exo_player_screen.dart';
import '../trailer/trailer_screen.dart';
import 'cubit/detail_cubit.dart';

part 'detail_screen_tv.dart';

/// Last-resort friendly name for a [sourceId] that's neither a loaded JS nor CS
/// provider (e.g. its source was uninstalled): drop the `cs:` prefix and the
/// `@version@tag` file-id suffix so the detail screen never shows "cs:X@31".
String _friendlySourceId(String sourceId) {
  var s = sourceId.startsWith('cs:')
      ? sourceId.substring(3)
      : sourceId.startsWith('ani:')
      ? sourceId.substring(4)
      : sourceId;
  final at = s.indexOf('@');
  if (at > 0) s = s.substring(0, at);
  return s;
}

/// "Source · Repo" label for the detail screen, so the user can see which repo
/// a source came from. Falls back to just the name when no repo is resolvable.
String _sourceLabel(String sourceId) {
  // Aniyomi sources (ani:<id>) resolve to their extension's display name;
  // otherwise the detail screen would show the raw "ani:4383278740…" id.
  if (sourceId.startsWith('ani:')) {
    final name = sl<SourceRepository>().displayName(sourceId);
    return name == sourceId ? _friendlySourceId(sourceId) : name;
  }
  final js = sl<ProviderRegistry>().entryFor(sourceId);
  if (js != null) {
    final name = js.displayName.isNotEmpty ? js.displayName : js.name;
    final repo = _repoLabelFromUrl(js.originRepoUrl);
    return repo != null ? '$name · $repo' : name;
  }
  final cs = sl<CloudStreamManager>().get(sourceId);
  if (cs is CloudStreamProvider) {
    // A disambiguated source's displayName already carries its repo tag, so
    // don't append the repo twice.
    final repo = cs.disambiguate
        ? null
        : sl<CloudStreamManager>().repoNameForSourceId(sourceId);
    return repo != null ? '${cs.displayName} · $repo' : cs.displayName;
  }
  return cs?.displayName ?? _friendlySourceId(sourceId);
}

/// Short repo label from a manifest URL (GitHub repo name, else owner, else
/// host). Null for bundled/blank URLs. Mirrors the source switcher's logic.
String? _repoLabelFromUrl(String? repoUrl) {
  if (repoUrl == null || repoUrl.isEmpty || repoUrl.startsWith('bundled://')) {
    return null;
  }
  try {
    final u = Uri.parse(repoUrl);
    final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
    if (u.host.contains('github')) {
      if (segs.length >= 2) return segs[1];
      if (segs.isNotEmpty) return segs.first;
    }
    return u.host.isEmpty ? null : u.host;
  } catch (_) {
    return null;
  }
}

class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key, required this.item});
  final MediaItem item;

  /// Opening transition: the page fades in while sliding up and scaling from
  /// 0.96 — a smooth "rise" into the detail rather than the platform push.
  static Route<void> route(MediaItem item) => PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 340),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) => DetailScreen(item: item),
    transitionsBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.035),
            end: Offset.zero,
          ).animate(curved),
          child: ScaleTransition(
            scale: Tween(begin: 0.96, end: 1.0).animate(curved),
            child: child,
          ),
        ),
      );
    },
  );

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

  // The episode url we've already kicked a background source-prefetch for, so we
  // don't re-fire it on every rebuild (see _maybePrefetch).
  String? _prefetchedEpUrl;

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

  // ── My List (status-organised library) ────────────────────────────────────
  final MyListStore _myList = sl<MyListStore>();
  final ListStatusStore _listStatus = sl<ListStatusStore>();
  late WatchStatus? _status = _listStatus.statusOf(widget.item);
  late bool _inMyList = _status != null || _myList.contains(widget.item);

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
  void initState() {
    super.initState();
    // Discord Rich Presence: "Looking at <title>" while this detail is open.
    if (sl.isRegistered<DiscordRpc>()) {
      sl<DiscordRpc>().setBrowsing(
        title: widget.item.title,
        posterUrl: widget.item.cover,
      );
    }
  }

  @override
  void dispose() {
    // Back to generic "Browsing" when leaving the detail.
    if (sl.isRegistered<DiscordRpc>()) sl<DiscordRpc>().setBrowsing();
    _scrollController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  /// Background-resolve [epUrl]'s sources once for this title, AFTER the current
  /// frame (so it never competes with rendering/scrolling), so the next Play
  /// reuses the work. Fire-and-forget; cancelled implicitly by leaving (the
  /// result just lands in the repo's prefetch cache, unused).
  void _maybePrefetch(String epUrl, String sourceId) {
    if (_prefetchedEpUrl == epUrl) return;
    _prefetchedEpUrl = epUrl;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      sl<SourceRepository>().prefetch(epUrl, sourceId: sourceId);
    });
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

  /// Switch to [index] AND collapse the header so the tab's content is actually
  /// in view — otherwise tapping "… more"/"Read more" silently changes a tab
  /// that's still below the fold (feels like nothing happened). Animates both
  /// for a smooth transition into the Cast / Details tab.
  void _revealTab(int index) {
    _tabController.animateTo(index);
    if (_scrollController.hasClients) {
      final target = _scrollController.position.maxScrollExtent;
      if (_scrollController.offset < target - 1) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
      }
    }
  }

  // ── The 5-icon action row wiring ──────────────────────────────────────────

  /// Open the "Add to List" status sheet (Plan / Watching / Completed / Paused
  /// / Dropped / Remove). Works locally for any title; for anime with a MAL id
  /// and AniList connected, the choice is also pushed to AniList.
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

  /// Open a related title. Relations come from a metadata API (not tied to a
  /// provider URL), so we search the CURRENT source for the title and open the
  /// first match's detail. Falls back to a snackbar when nothing is found.
  Future<void> _openRelation(MediaRelation r) async {
    _snack('Finding “${r.title}”…');
    try {
      final results = await sl<SourceRepository>().search(
        r.title,
        sourceId: widget.item.sourceId,
      );
      if (!mounted) return;
      final match = bestTitleMatch(
        results,
        r.title,
        altTitle: r.romaji,
        wantedMalId: r.malId,
      );
      if (match == null) {
        _snack('“${r.title}” isn’t on this source');
        return;
      }
      Navigator.of(context).push(DetailScreen.route(match));
    } catch (_) {
      if (mounted) _snack('Couldn’t open “${r.title}”');
    }
  }

  void _share(MediaDetail detail, String sourceName) {
    // Native OS share sheet with a Zangetsu deep link: on tap it opens the app
    // straight to this title (on its source) if installed, else the Zangetsu
    // site to download. The link carries the item, so sourceName is unused now.
    SharePlus.instance.share(
      ShareParams(text: ShareLink.shareText(widget.item)),
    );
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

  bool get _subscribed =>
      sl<SubscriptionStore>().contains(widget.item.sourceId, widget.item.url);

  /// Toggle "notify on new episodes" for this show. On subscribe we seed the
  /// baseline to the current episode count so only FUTURE episodes alert.
  Future<void> _toggleSubscribe(MediaDetail detail) async {
    final store = sl<SubscriptionStore>();
    final item = widget.item;
    if (_subscribed) {
      await store.remove(item.sourceId, item.url);
      _snack('Notifications off for “${item.title}”');
    } else {
      await store.add(
        Subscription(
          sourceId: item.sourceId,
          url: item.url,
          title: item.title.isNotEmpty ? item.title : detail.title,
          cover: item.cover,
          coverHeaders: item.coverHeaders,
          lastCount: detail.episodes.length,
        ),
      );
      await NotificationService.instance.init(); // ask for permission now
      _snack('You’ll be notified of new episodes of “${item.title}”');
    }
    // Mirror CS subs to native so the background worker picks up the change.
    await CsNotify.sync(store.all());
    if (mounted) setState(() {});
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
          scrobbleTitle: detail.type == ProviderType.anime
              ? detail.title
              : null,
          tmdbId: detail.tmdbId ?? widget.item.tmdbId,
          tmdbIsTv: detail.tmdbIsTv,
          imdbId: detail.imdbId ?? widget.item.imdbId,
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
      final mark = store.get(widget.item.sourceId, widget.item.url, eps[j].id);
      if (mark != null) {
        highestMarked = j;
      }
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

  // ── Downloads ─────────────────────────────────────────────────────────────

  /// The main Download button. A single movie/episode goes straight to the
  /// server picker; a multi-episode title opens the batch sheet (season chips +
  /// tappable episode selection + quality).
  Future<void> _openDownloadSheet({
    required MediaDetail detail,
    required String category,
    required Map<int, List<Episode>> episodesBySeason,
    required int initialSeason,
  }) async {
    final total = episodesBySeason.values.fold<int>(0, (a, b) => a + b.length);
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
    // Sub/Dub the title actually offers; the sheet only shows the toggle when
    // there's more than one. Defaults to the page's current category (seeded
    // from the per-title remembered choice).
    final availableCategories = <String>[
      if ((detail.subCount ?? 0) > 0) 'sub',
      if ((detail.dubCount ?? 0) > 0) 'dub',
    ];
    final res =
        await showModalBottomSheet<
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

  /// Re-resolve a title's episodes for a given sub/dub [category] (without
  /// touching the detail page's own toggle), grouped by season.
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
    final res =
        await showModalBottomSheet<
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
            resolve: () =>
                sl<SourceRepository>().sources(ep.url, sourceId: item.sourceId),
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

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return DetailScreenTv(item: widget.item);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: BlocBuilder<DetailCubit, DetailState>(
        builder: (context, state) {
          if (state.status == DetailStatus.loading) {
            return const _DetailSkeleton(heroHeight: _expandedHeight);
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
    // Warm the stream for the episode Play will start, in the background, so
    // tapping Play is near-instant. Deferred to after this frame so it can't
    // affect the detail screen's rendering/scroll.
    if (eps.isNotEmpty) _maybePrefetch(eps[resumeIdx].url, item.sourceId);
    final hasAnyMark = eps.any(
      (e) => store.get(item.sourceId, item.url, e.id) != null,
    );
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

    // Episodes grouped by season for the download sheet's season chips.
    final episodesBySeason = <int, List<Episode>>{};
    if (hasMultipleSeasons) {
      for (final e in eps) {
        (episodesBySeason[parseSeason(e.title) ?? 1] ??= <Episode>[]).add(e);
      }
    } else {
      episodesBySeason[1] = eps;
    }

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
    // Prefer enriched cast (AniList/TMDB) when available, else the provider's.
    final castNames = state.cast.isNotEmpty
        ? state.cast.map((c) => c.name).toList()
        : detail.cast;
    final starring = castNames.isNotEmpty ? castNames.take(3).join(', ') : null;
    final starringMore = castNames.length > 3;
    final creators = detail.studios.isNotEmpty
        ? detail.studios.join(', ')
        : null;
    // For anime (or anything without cast) surface Genres instead of an empty
    // Starring line — never show an empty label.
    final genresLine = (starring == null && detail.genres.isNotEmpty)
        ? detail.genres.take(4).join(', ')
        : null;

    // Friendly provider name + its origin repo, so the user can tell which repo
    // a source came from. JS providers live in the registry; CloudStream sources
    // live in the CS manager — without the CS lookup this fell back to the raw
    // sourceId ("cs:Provider@31@tag"), leaking the file-id suffix.
    final sourceName = _sourceLabel(item.sourceId);

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
                  // Tapping the title opens the full search pre-filled with it
                  // (current source + all sources, per Search's own scope toggle).
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            SearchScreen(initialQuery: detail.title),
                      ),
                    ),
                    child: Text(
                      detail.title,
                      style: AppText.largeTitle.copyWith(fontSize: 28),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
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
                    category: category,
                    episodesBySeason: episodesBySeason,
                    initialSeason: currentSeason,
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
                // "Read more" reveals the Details tab (full synopsis) rather
                // than expanding inline; the header stays clamped to 3 lines.
                onReadMore: () => _revealTab(3),
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
                      // Tapping the line (or its "… more") reveals the Cast tab.
                      onMore: starringMore ? () => _revealTab(1) : null,
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
                  label: _status?.shortLabel ?? 'My List',
                  tooltip: _inMyList ? 'Change status' : 'Add to My List',
                  onTap: () => _openListSheet(detail),
                ),
                if (Platform.isAndroid)
                  _IconAction(
                    icon: _subscribed
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    active: _subscribed,
                    label: 'Notify',
                    tooltip: _subscribed
                        ? 'Stop new-episode alerts'
                        : 'Notify on new episodes',
                    onTap: () => _toggleSubscribe(detail),
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
              indicator: UnderlineTabIndicator(
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
            showId: item.id,
            showUrl: item.url,
            resumeIndex: _resumeIndex,
            hasAnyMark: hasAnyMark,
            onOpen: (fullIndex) =>
                _openPlayer(eps, fullIndex, detail, category),
            onInfo: () => _tabController.animateTo(3),
            onDownload: (ep) => _downloadSingle(ep, detail, category),
          ),
          // ── Cast ────────────────────────────────────────────────────────────
          _CastTab(
            cast: state.cast.isNotEmpty
                ? state.cast
                : [for (final n in detail.cast) CastMember(name: n)],
            onOpenPerson: (ref) => Navigator.of(context).push(
              PersonPage.route(ref, sourceId: widget.item.sourceId),
            ),
          ),
          // ── Relations ─────────────────────────────────────────────────────────
          _RelationsTab(relations: state.relations, onOpen: _openRelation),
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
    if (!hasCover) return ColoredBox(color: AppColors.surface2);
    // Aniyomi path: when the x-ani-src marker is present, fetch image bytes
    // through the source's own OkHttpClient (which carries the CF session)
    // instead of CachedNetworkImage which cannot pass Cloudflare.
    final aniSrcId = coverHeaders?['x-ani-src'];
    if (aniSrcId != null) {
      return Image(
        image: AniyomiImage(int.parse(aniSrcId), coverUrl),
        fit: BoxFit.cover,
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : ColoredBox(color: AppColors.surface2),
        errorBuilder: (context, error, stackTrace) =>
            ColoredBox(color: AppColors.surface2),
      );
    }
    return CachedNetworkImage(
      imageUrl: coverUrl,
      httpHeaders: coverHeaders,
      fit: BoxFit.cover,
      memCacheWidth: 800,
      placeholder: (c, u) => ColoredBox(color: AppColors.surface2),
      errorWidget: (c, u, e) => ColoredBox(color: AppColors.surface2),
    );
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
  // User-facing play/pause intent (separate from the scroll-driven collapse
  // pause). Seeded from the "Autoplay trailer" setting: off → start paused.
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _paused = !sl<PlaybackPrefs>().autoplayTrailer;
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
      if (done && mounted && !widget.collapsed && !_paused) {
        _player?.seek(Duration.zero);
        _player?.play();
      }
    });

    try {
      // Open WITHOUT relying solely on open(play:) — some engines/platforms
      // don't honor the autoplay flag until the first user interaction. Open
      // paused, then explicitly play() the moment the media is loaded and the
      // widget is still mounted, so the trailer starts on its own with no touch.
      final autostart = !_paused && !widget.collapsed;
      await player.open(Media(url), play: autostart);
      if (!mounted) return;
      // Autostart only when the hero is on-screen AND the user hasn't paused
      // (via the button or the "Autoplay trailer" setting being off). If it's
      // paused or already scrolled past, stay put — the play button and the
      // collapsed handler in didUpdateWidget start it later.
      if (autostart) {
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
    // Pause when scrolled past the hero; resume when it's expanded again —
    // but never resume a trailer the user deliberately paused.
    if (widget.collapsed != old.collapsed && !_errored) {
      if (widget.collapsed) {
        _player?.pause();
      } else if (!_paused) {
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

  Future<void> _togglePlay() async {
    final player = _player;
    if (player == null) return;
    final next = !_paused;
    setState(() => _paused = next);
    if (next) {
      await player.pause();
    } else if (!widget.collapsed) {
      await player.play();
    }
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
    final topInset = MediaQuery.of(context).padding.top;
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
        // Controls — a horizontal row at top-right (clear of the top-left back
        // arrow and the bottom subtitles): play/pause then mute. Offset below
        // the status bar. Play/pause shows as soon as the player exists (so a
        // paused-start trailer can be started); mute only once it's actually
        // playing (mute is meaningless before that).
        if (controller != null && !_errored)
          Positioned(
            right: 14,
            top: topInset + 8,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _HeroCircleButton(
                  icon: _paused
                      ? Icons.play_arrow_rounded
                      : Icons.pause_rounded,
                  onTap: _togglePlay,
                ),
                if (_ready) ...[
                  const SizedBox(width: 8),
                  _HeroCircleButton(
                    icon: _muted
                        ? Icons.volume_off_rounded
                        : Icons.volume_up_rounded,
                    onTap: _toggleMute,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

// Small translucent circular icon button for the hero trailer controls
// (mute/unmute and play/pause).
class _HeroCircleButton extends StatelessWidget {
  const _HeroCircleButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The visible circle is 36dp, but the tap target is a full 48dp. Using an
    // opaque GestureDetector (NOT an InkWell, which defers hit-testing to its
    // painted child) so the whole 48dp square absorbs the tap — otherwise taps
    // in the ring around the icon fall through to the banner's fullscreen
    // gesture behind, which is what made the buttons feel unresponsive.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0x66000000),
              shape: BoxShape.circle,
            ),
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: Colors.white, size: 20),
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
                style: base.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
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
    required this.showId,
    required this.showUrl,
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
  final String showId;
  final String showUrl;
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
    final mark = store.get(widget.sourceId, widget.showUrl, ep.id);
    final inProgress =
        mark != null && !mark.finished && mark.duration > Duration.zero;
    final watched = mark != null && mark.finished;
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
        final displayTitle = widget.hasMultipleSeasons
            ? cleanTitle(ep.title)
            : ep.title;
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
            showId: widget.showId,
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
    required this.showId,
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
  final String showId;

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
                                  placeholder: (c, u) => ColoredBox(
                                    color: AppColors.surface2,
                                  ),
                                  errorWidget: (c, u, e) => ColoredBox(
                                    color: AppColors.surface2,
                                  ),
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
                // Per-episode download icon (phone only). On TV it's redundant
                // clutter next to the main Download button + hard to focus, so
                // it's hidden — the TV path downloads via the Download action.
                if (!sl<AppMode>().isTv) ...[
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
        return _glyph(rec?.status, rec?.progress ?? 0);
      },
    );
  }

  Widget _glyph(DownloadStatus? status, double progress) {
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
    return IconButton(
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      splashRadius: 22,
      icon: child,
    );
  }
}

/// A readable name for a source row. Providers like 4khdhub set a rich [label];
/// AllAnime sets neither label nor quality, so fall back to the host (or a
/// numbered server) instead of rendering a blank row.
String _sourceName(VideoSource s, int index) {
  final l = s.label?.trim();
  if (l != null && l.isNotEmpty) return l;
  final q = s.quality?.trim();
  if (q != null && q.isNotEmpty) return q;
  final host = (Uri.tryParse(s.url)?.host ?? '').replaceFirst('www.', '');
  return host.isNotEmpty
      ? 'Server ${index + 1} · $host'
      : 'Server ${index + 1}';
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
              Padding(
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
                  itemBuilder: (context, i) => _row(_sources![i], i),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(VideoSource s, int i) {
    final hls = _isHls(s);
    final label = _sourceName(s, i);
    final sub = [
      if (s.quality != null && s.quality!.trim().isNotEmpty) s.quality!.trim(),
      hls ? 'HLS' : 'Direct',
    ].join(' · ');
    void onTap() =>
        Navigator.pop(context, (chosen: s, all: _sources ?? <VideoSource>[s]));
    if (sl<AppMode>().isTv) {
      return TvFocusable(
        autofocus: i == 0,
        onTap: onTap,
        child: ListTile(
          contentPadding: const EdgeInsets.only(right: 8),
          leading: Icon(Icons.download_rounded, color: AppColors.accent),
          title: Text(
            label,
            style: AppText.body.copyWith(color: AppColors.textPrimary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(sub, style: AppText.caption),
        ),
      );
    }
    return ListTile(
      contentPadding: const EdgeInsets.only(right: 8),
      leading: Icon(Icons.download_rounded, color: AppColors.accent),
      title: Text(
        label,
        style: AppText.body.copyWith(color: AppColors.textPrimary),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(sub, style: AppText.caption),
      onTap: onTap,
    );
  }
}

// Download sheet — season dropdown (multi-season) + a real SOURCE/quality list
// (resolved from the season's first episode, like the player) + tappable
// thumbnail episode rows you multi-select. Returns the chosen (quality,
// episodes) via pop; the quality drives per-episode source selection.
class _DownloadSheet extends StatefulWidget {
  const _DownloadSheet({
    required this.title,
    required this.episodesBySeason,
    required this.initialSeason,
    required this.resolve,
    required this.coverUrl,
    required this.coverHeaders,
    required this.initialCategory,
    required this.availableCategories,
    required this.resolveEpisodes,
  });

  final String title;
  final Map<int, List<Episode>> episodesBySeason;
  final int initialSeason;
  final Future<List<VideoSource>> Function(Episode) resolve;
  final String coverUrl;
  final Map<String, String>? coverHeaders;

  /// Current sub/dub category + what the title offers. The Sub/Dub toggle is
  /// only shown when [availableCategories] has more than one. Switching it
  /// re-resolves the episode list via [resolveEpisodes].
  final String initialCategory;
  final List<String> availableCategories;
  final Future<Map<int, List<Episode>>> Function(String category)
  resolveEpisodes;

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  String _quality = 'best';
  late int _season;
  late String _category;
  late Map<int, List<Episode>> _episodesBySeason;
  final Set<String> _selectedIds = {};
  late Map<String, Episode> _byId;

  // Real, resolved download sources for the current season's first episode.
  List<VideoSource>? _sources; // null = loading, [] = none found
  bool _loadingSources = true;
  int _selectedSourceIdx = 0;

  // Episode search/filter (phone + TV). No autofocus so the TV leanback
  // keyboard doesn't pop the moment the sheet opens.
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _season = widget.initialSeason;
    _category = widget.initialCategory;
    _episodesBySeason = widget.episodesBySeason;
    _byId = {
      for (final eps in _episodesBySeason.values)
        for (final e in eps) e.id: e,
    };
    // Default to the whole current season selected so Download is enabled
    // immediately (the common "download this season" case); the user can Clear
    // or toggle tiles to narrow it.
    _selectedIds.addAll(
      (_episodesBySeason[_season] ?? const <Episode>[]).map((e) => e.id),
    );
    _resolveSources();
  }

  /// Switch sub/dub: re-resolve the episode list for [cat] (dub episodes have
  /// different URLs), keep the season if it still exists, then re-resolve the
  /// source/quality options.
  Future<void> _setCategory(String cat) async {
    if (cat == _category) return;
    setState(() {
      _category = cat;
      _loadingSources = true;
      _sources = null;
    });
    try {
      final byS = await widget.resolveEpisodes(cat);
      if (!mounted) return;
      final seasons = byS.keys.toList()..sort();
      final season = byS.containsKey(_season)
          ? _season
          : (seasons.isEmpty ? _season : seasons.first);
      setState(() {
        _episodesBySeason = byS;
        _byId = {
          for (final eps in byS.values)
            for (final e in eps) e.id: e,
        };
        _season = season;
        _selectedIds
          ..clear()
          ..addAll((byS[season] ?? const <Episode>[]).map((e) => e.id));
      });
      await _resolveSources();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingSources = false;
          _sources = [];
        });
      }
    }
  }

  int _h(VideoSource s) {
    final m = RegExp(r'(\d{3,4})').firstMatch(s.quality ?? '');
    return m == null ? 0 : int.parse(m.group(1)!);
  }

  /// Resolve the first episode of the current season to show the real
  /// server/quality options (the batch download applies the chosen quality to
  /// every selected episode).
  Future<void> _resolveSources() async {
    setState(() {
      _loadingSources = true;
      _sources = null;
    });
    final eps = _seasonEps;
    if (eps.isEmpty) {
      setState(() {
        _loadingSources = false;
        _sources = [];
      });
      return;
    }
    try {
      final all = await widget.resolve(eps.first);
      if (!mounted) return;
      // HLS + direct are both downloadable now; show them all, best first.
      final ranked = all.toList()..sort((a, b) => _h(b).compareTo(_h(a)));
      setState(() {
        _sources = ranked;
        _selectedSourceIdx = 0;
        _quality = ranked.isNotEmpty
            ? (ranked.first.quality ?? 'best')
            : 'best';
        _loadingSources = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingSources = false;
          _sources = [];
        });
      }
    }
  }

  List<int> get _seasons => _episodesBySeason.keys.toList()..sort();
  bool get _multiSeason => _seasons.length > 1;
  List<Episode> get _seasonEps => _episodesBySeason[_season] ?? const [];

  /// The current season's episodes narrowed by the search query. Equals
  /// [_seasonEps] when the query is empty, so every path below is unchanged
  /// when the user isn't searching.
  List<Episode> get _filtered => filterEpisodes(_seasonEps, _query);

  List<Episode> get _selectedEpisodes =>
      (_selectedIds.map((id) => _byId[id]).whereType<Episode>().toList())
        ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));

  int _epNum(Episode e, int i) => e.number?.toInt() ?? (i + 1);

  // Select-all / Clear act on the *filtered* view, so "filter to OVA →
  // Select all" grabs just the matches. With no query, _filtered == _seasonEps.
  void _selectAllInSeason() =>
      setState(() => _selectedIds.addAll(_filtered.map((e) => e.id)));

  void _clearSeason() =>
      setState(() => _selectedIds.removeAll(_filtered.map((e) => e.id)));

  bool get _allSeasonSelected =>
      _filtered.isNotEmpty &&
      _filtered.every((e) => _selectedIds.contains(e.id));

  @override
  Widget build(BuildContext context) {
    final count = _selectedIds.length;
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

            // ── Season dropdown ────────────────────────────────────────────
            if (_multiSeason) ...[
              const SizedBox(height: 18),
              Text('Season', style: AppText.overline),
              const SizedBox(height: 8),
              _seasonDropdown(),
            ],

            // ── Audio (Sub / Dub) — only when the title offers both ─────────
            if (widget.availableCategories.length > 1) ...[
              const SizedBox(height: 18),
              Text('Audio', style: AppText.overline),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final c in widget.availableCategories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _categoryChip(c),
                    ),
                ],
              ),
            ],

            // ── Source / quality (resolved from the first episode) ─────────
            const SizedBox(height: 18),
            Text('Source', style: AppText.overline),
            const SizedBox(height: 8),
            _sourceSection(),

            // ── Episode multi-select (horizontal thumbnail cards) ──────────
            const SizedBox(height: 20),
            // Filter box — only when there's a list long enough to be worth it.
            if (_seasonEps.length > 5) ...[
              _episodeSearchField(),
              const SizedBox(height: 14),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_selectedIds.length}/${_seasonEps.length} episodes',
                  style: AppText.overline,
                ),
                _textBtn(
                  _allSeasonSelected ? 'Clear' : 'Select all',
                  _allSeasonSelected ? _clearSeason : _selectAllInSeason,
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 118,
              child: _filtered.isEmpty && _query.isNotEmpty
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'No episodes match',
                        style: AppText.body
                            .copyWith(color: AppColors.textTertiary),
                      ),
                    )
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.zero,
                      itemCount: _filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (c, i) {
                        final ep = _filtered[i];
                        // Pass the ORIGINAL season index so a numberless
                        // episode's E-number fallback stays correct.
                        return _episodeCard(ep, _seasonEps.indexOf(ep));
                      },
                    ),
            ),

            // ── Download button ────────────────────────────────────────────
            const SizedBox(height: 16),
            if (sl<AppMode>().isTv)
              TvFocusable(
                autofocus: true,
                onTap: count == 0
                    ? () {}
                    : () => Navigator.pop(context, (
                        quality: _quality,
                        category: _category,
                        episodes: _selectedEpisodes,
                      )),
                child: Material(
                  color: count == 0 ? AppColors.surface2 : AppColors.accent,
                  borderRadius: BorderRadius.circular(10),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    height: 50,
                    width: double.infinity,
                    child: Center(
                      child: Text(
                        count == 0
                            ? 'Select episodes'
                            : 'Download $count episode${count == 1 ? '' : 's'}',
                        style: AppText.button.copyWith(
                          color: count == 0
                              ? AppColors.textTertiary
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            else
              Material(
                color: count == 0 ? AppColors.surface2 : AppColors.accent,
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: count == 0
                      ? null
                      : () => Navigator.pop(context, (
                          quality: _quality,
                          category: _category,
                          episodes: _selectedEpisodes,
                        )),
                  child: SizedBox(
                    height: 50,
                    width: double.infinity,
                    child: Center(
                      child: Text(
                        count == 0
                            ? 'Select episodes'
                            : 'Download $count episode${count == 1 ? '' : 's'}',
                        style: AppText.button.copyWith(
                          color: count == 0
                              ? AppColors.textTertiary
                              : Colors.white,
                        ),
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

  Widget _episodeSearchField() {
    return TextField(
      controller: _searchCtrl,
      focusNode: _searchFocus,
      onChanged: (v) => setState(() => _query = v),
      style: AppText.body.copyWith(color: AppColors.textPrimary),
      cursorColor: AppColors.accent,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search episodes',
        hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
        prefixIcon: const Icon(Icons.search_rounded,
            color: AppColors.textTertiary, size: 20),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded,
                    color: AppColors.textTertiary, size: 20),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
              ),
        filled: true,
        fillColor: AppColors.surface2,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _categoryChip(String c) {
    final selected = c == _category;
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Text(
        c == 'dub' ? 'Dub' : 'Sub',
        style: AppText.body.copyWith(
          color: selected ? Colors.white : AppColors.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    if (sl<AppMode>().isTv) {
      return TvFocusable(
        onTap: () => _setCategory(c),
        child: Material(
          color: selected ? AppColors.accent : AppColors.surface2,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          child: label,
        ),
      );
    }
    return Material(
      color: selected ? AppColors.accent : AppColors.surface2,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: () => _setCategory(c), child: label),
    );
  }

  Widget _sourceSection() {
    if (_loadingSources) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: AppColors.accent,
            ),
          ),
        ),
      );
    }
    final srcs = _sources ?? const <VideoSource>[];
    if (srcs.isEmpty) {
      // Couldn't resolve here (e.g. HLS-only) — each episode still tries at
      // download time; fall back to best available.
      return Text(
        'Auto · best available',
        style: AppText.caption.copyWith(color: AppColors.textSecondary),
      );
    }
    final maxH = MediaQuery.of(context).size.height * 0.22;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (var i = 0; i < srcs.length; i++) _sourceRow(srcs[i], i),
          ],
        ),
      ),
    );
  }

  Widget _sourceRow(VideoSource s, int i) {
    final sel = i == _selectedSourceIdx;
    final label = _sourceName(s, i);
    final hasQuality = s.quality != null && s.quality!.trim().isNotEmpty;
    void onTap() => setState(() {
      _selectedSourceIdx = i;
      _quality = hasQuality ? s.quality!.trim() : 'best';
    });
    final content = Row(
      children: [
        Icon(
          sel ? Icons.radio_button_checked : Icons.radio_button_off,
          color: sel ? AppColors.accent : AppColors.textTertiary,
          size: 18,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: AppText.caption.copyWith(color: AppColors.textPrimary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (hasQuality) ...[
          const SizedBox(width: 8),
          Text(
            s.quality!.trim(),
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ],
    );
    if (sl<AppMode>().isTv) {
      // Match the Sub/Dub chip: a clean Material with NO own border, and the
      // 8px gap OUTSIDE TvFocusable so its focus ring hugs the row (was offset
      // by an inner margin + fought the row's own border — the "misaligned,
      // day-and-night" highlight testers reported). Selection = accent fill +
      // checked radio; focus = TvFocusable's ring.
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TvFocusable(
          scale: 1.0, // full-width row — scaling overflows the sheet edges
          onTap: onTap,
          child: Material(
            color: sel ? AppColors.accentSoft : AppColors.surface2,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: content,
            ),
          ),
        ),
      );
    }
    final visual = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: sel ? AppColors.accentSoft : AppColors.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: sel ? AppColors.accent : AppColors.hairline,
          width: sel ? 1 : 0.5,
        ),
      ),
      child: content,
    );
    return GestureDetector(onTap: onTap, child: visual);
  }

  /// Season dropdown pill — opens the shared dark season picker sheet.
  Widget _seasonDropdown() {
    Future<void> openPicker() async {
      final picked = await showModalBottomSheet<int>(
        context: context,
        backgroundColor: AppColors.surface,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (_) => _SeasonSheet(seasons: _seasons, currentSeason: _season),
      );
      if (picked != null && picked != _season) {
        setState(() {
          _season = picked;
          _query = ''; // don't carry a stale filter into the new season
          _searchCtrl.clear();
        });
        _resolveSources(); // sources differ per season
      }
    }

    final visual = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(child: Text('Season $_season', style: AppText.headline)),
          const Icon(
            Icons.keyboard_arrow_down_rounded,
            color: AppColors.textPrimary,
            size: 22,
          ),
        ],
      ),
    );

    if (sl<AppMode>().isTv) {
      return TvFocusable(
        onTap: openPicker,
        child: Material(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: visual,
        ),
      );
    }
    return Material(
      color: AppColors.surface2,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: openPicker, child: visual),
    );
  }

  /// Horizontal episode card: 16:9 thumbnail with a selection check overlay +
  /// "E{n}" and the title beneath. Tap to toggle.
  Widget _episodeCard(Episode e, int i) {
    final sel = _selectedIds.contains(e.id);
    final thumb = (e.thumbnail != null && e.thumbnail!.isNotEmpty)
        ? e.thumbnail!
        : widget.coverUrl;
    final epNum = _epNum(e, i);
    final title = e.title.trim();
    final hasTitle = title.isNotEmpty && title != 'Episode $epNum';
    void onTap() => setState(() {
      if (sel) {
        _selectedIds.remove(e.id);
      } else {
        _selectedIds.add(e.id);
      }
    });
    final card = SizedBox(
      width: 132,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            // Selection = a thin accent ring around the thumbnail (no heavy
            // colour wash).
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: sel ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                children: [
                  SizedBox(
                    width: 132,
                    height: 74, // 16:9
                    child: thumb.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: thumb,
                            httpHeaders: widget.coverHeaders,
                            fit: BoxFit.cover,
                            memCacheWidth: 280,
                            placeholder: (c, u) =>
                                ColoredBox(color: AppColors.surface2),
                            errorWidget: (c, u, e) =>
                                ColoredBox(color: AppColors.surface2),
                          )
                        : ColoredBox(color: AppColors.surface2),
                  ),
                  // Small check badge — filled accent only when selected, a
                  // subtle dark chip otherwise (so it reads on any thumbnail).
                  Positioned(
                    top: 5,
                    right: 5,
                    child: Container(
                      decoration: BoxDecoration(
                        color: sel ? AppColors.accent : const Color(0x99000000),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        sel ? Icons.check_rounded : Icons.add_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'E$epNum',
            style: AppText.caption.copyWith(
              color: sel ? AppColors.accent : AppColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (hasTitle)
            Text(
              title,
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
    if (sl<AppMode>().isTv) {
      return TvFocusable(onTap: onTap, child: card);
    }
    return GestureDetector(onTap: onTap, child: card);
  }

  Widget _textBtn(String label, VoidCallback onTap) {
    if (sl<AppMode>().isTv) {
      return TvFocusable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            label,
            style: AppText.caption.copyWith(
              color: AppColors.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: AppText.caption.copyWith(
          color: AppColors.accent,
          fontWeight: FontWeight.w700,
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
            child: ColoredBox(color: AppColors.accent),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cast tab — chips of cast members; graceful empty state.
// ─────────────────────────────────────────────────────────────────────────────

/// [EmptyState] wrapped so it can sit in a [TabBarView] body inside a
/// [NestedScrollView]: scrollable (so the header can still collapse) and
/// centered via a min-height box, which avoids the bottom overflow when the
/// collapsed viewport is shorter than the icon + text.
Widget _emptyTab(IconData icon, String message) => LayoutBuilder(
  builder: (context, constraints) => SingleChildScrollView(
    physics: const AlwaysScrollableScrollPhysics(),
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: constraints.maxHeight),
      child: EmptyState(icon: icon, message: message),
    ),
  ),
);

class _CastTab extends StatelessWidget {
  const _CastTab({required this.cast, this.onOpenPerson});
  final List<CastMember> cast;

  /// Tapping a card with a resolved [CastMember.person] opens their page
  /// (character/actor). Cards without a person id (source-supplied cast) stay
  /// non-tappable.
  final void Function(PersonRef)? onOpenPerson;

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) {
      return _emptyTab(Icons.people_outline_rounded, 'No cast information');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.66,
      ),
      itemCount: cast.length,
      itemBuilder: (_, i) {
        final m = cast[i];
        final card = Column(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 1,
                child: (m.photo != null && m.photo!.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: m.photo!,
                        fit: BoxFit.cover,
                        placeholder: (_, _) =>
                            Container(color: AppColors.surface2),
                        errorWidget: (_, _, _) => const _AvatarFallback(),
                      )
                    : const _AvatarFallback(),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              m.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (m.role != null && m.role!.isNotEmpty)
              Text(
                m.role!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
          ],
        );
        final ref = m.person;
        if (ref == null || onOpenPerson == null) return card;
        return GestureDetector(
          onTap: () => onOpenPerson!(ref),
          behavior: HitTestBehavior.opaque,
          child: card,
        );
      },
    );
  }
}

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback();
  @override
  Widget build(BuildContext context) => Container(
    color: AppColors.surface2,
    alignment: Alignment.center,
    child: const Icon(
      Icons.person_rounded,
      color: AppColors.textTertiary,
      size: 30,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Relations tab — related/recommended titles; tap searches the active source.
// ─────────────────────────────────────────────────────────────────────────────

class _RelationsTab extends StatelessWidget {
  const _RelationsTab({
    required this.relations,
    required this.onOpen,
    this.tvFocus = false,
  });
  final List<MediaRelation> relations;
  final void Function(MediaRelation) onOpen;

  /// When true, each card is wrapped in [TvFocusable] so D-pad can navigate
  /// and select relation cards on TV.  Defaults to false — no phone caller
  /// passes this flag, so the phone render is byte-identical to the original.
  final bool tvFocus;

  @override
  Widget build(BuildContext context) {
    if (relations.isEmpty) {
      return _emptyTab(Icons.account_tree_outlined, 'No related titles');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 16,
        crossAxisSpacing: 12,
        childAspectRatio: 0.47,
      ),
      itemCount: relations.length,
      itemBuilder: (_, i) {
        final r = relations[i];
        final visual = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: (r.cover != null && r.cover!.isNotEmpty)
                    ? CachedNetworkImage(
                        imageUrl: r.cover!,
                        fit: BoxFit.cover,
                        placeholder: (_, _) =>
                            Container(color: AppColors.surface2),
                        errorWidget: (_, _, _) =>
                            Container(color: AppColors.surface2),
                      )
                    : Container(color: AppColors.surface2),
              ),
            ),
            const SizedBox(height: 6),
            if (r.relation != null && r.relation!.isNotEmpty)
              Text(
                r.relation!.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                  color: AppColors.accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            Text(
              r.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: AppColors.textPrimary),
            ),
          ],
        );
        // TV path: D-pad-navigable TvFocusable wrapper.
        if (tvFocus) {
          return TvFocusable(
            key: ValueKey('tv-rel-$i'),
            onTap: () => onOpen(r),
            child: visual,
          );
        }
        // Phone path: original GestureDetector — byte-identical to the old code.
        return GestureDetector(
          onTap: () => onOpen(r),
          behavior: HitTestBehavior.opaque,
          child: visual,
        );
      },
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

/// Shimmering placeholder shown while the detail loads — mirrors the real
/// layout (backdrop, title/meta, Play/Download, synopsis, credits) so the
/// screen eases in instead of popping from a blank spinner to a full page.
/// One shared [AnimationController] (same pattern as RowSkeleton/SkeletonGrid).
class _DetailSkeleton extends StatefulWidget {
  const _DetailSkeleton({required this.heroHeight});

  final double heroHeight;

  @override
  State<_DetailSkeleton> createState() => _DetailSkeletonState();
}

class _DetailSkeletonState extends State<_DetailSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    // One continuous forward sweep (not a reversing fade) reads as a real
    // shimmer rather than a dull pulse.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final base = AppColors.surface2;
    final highlight = Color.lerp(base, Colors.white, 0.14)!;

    Widget box(double w, double h, [double r = 8]) => ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: SizedBox(
        width: w,
        height: h,
        child: ColoredBox(color: base),
      ),
    );

    // The skeleton shapes, painted in the flat base colour. A moving highlight
    // is swept across them by the ShaderMask below.
    final shapes = SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            height: widget.heroHeight,
            child: ColoredBox(color: base),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                box(width * 0.66, 26), // title
                const SizedBox(height: 12),
                box(width * 0.42, 14), // meta line
                const SizedBox(height: 20),
                box(double.infinity, 50, 14), // Play
                const SizedBox(height: 10),
                box(double.infinity, 50, 14), // Download
                const SizedBox(height: 22),
                box(double.infinity, 12), // synopsis line 1
                const SizedBox(height: 9),
                box(double.infinity, 12), // synopsis line 2
                const SizedBox(height: 9),
                box(width * 0.55, 12), // synopsis line 3
                const SizedBox(height: 22),
                box(width * 0.5, 13), // starring
                const SizedBox(height: 12),
                box(width * 0.4, 13), // creators / genres
              ],
            ),
          ),
        ],
      ),
    );

    // A diagonal highlight band swept across the masked shapes — the classic
    // shimmer sheen, far livelier than a flat opacity pulse.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        child: shapes,
        builder: (context, child) {
          final t =
              _ctrl.value * 3 - 1; // -1 → 2 : band enters left, exits right
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [base, highlight, base],
              stops: const [0.32, 0.5, 0.68],
              transform: _SlideGradient(t),
            ).createShader(bounds),
            child: child,
          );
        },
      ),
    );
  }
}

/// Translates a gradient horizontally by [t] × width — used to sweep the
/// shimmer highlight across the skeleton.
class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.t);

  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * t, 0, 0);
}
