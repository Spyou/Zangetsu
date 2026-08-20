import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart' show CupertinoPicker;
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
import '../../core/metadata/episode_metadata_service.dart';
import '../../core/metadata/metadata_enrichment.dart';
import '../../core/notify/cs_notify.dart';
import '../../core/notify/notification_service.dart';
import '../../core/notify/subscription_store.dart';
import '../../core/share/share_link.dart';
import '../../core/download/download_manager.dart';
import '../../core/download/download_record.dart';
import '../../core/models/episode.dart';
import '../../core/models/episode_title.dart';
import '../../core/models/media_detail.dart';
import 'chapter_meta.dart';
import 'episode_filter.dart';
import '../../core/models/media_item.dart';
import '../../core/models/media_extras.dart';
import '../../core/models/person.dart';
import '../home/search_screen.dart';
import '../people/person_page.dart';
import '../../core/models/video_source.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/filler_service.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/privacy/incognito_mode.dart';
import '../../core/playback/my_list.dart';
import '../../core/ui/episode_player_sheet.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/tracker_sync_sheet.dart';
import '../../core/tracker/airing_countdown.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_binding_store.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/reading/read_history.dart';
import '../../core/reading/read_store.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/trailer/trailer_service.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_load_error_dialog.dart';
import '../../core/aniyomi/aniyomi_image_provider.dart';
import '../../core/mihon/mihon_image_provider.dart';
import '../../core/ui/badge.dart';
import '../../core/ui/route_observer.dart';
import '../../core/ui/states.dart';
import '../player/player_screen.dart';
import '../player/tv_exo_player_screen.dart';
import '../player/tv_native_player.dart'; // used by the detail_screen_tv.dart part
import '../reader/manga_reader_screen.dart';
import '../reader/novel_reader_screen.dart';
import '../trailer/trailer_screen.dart';
import 'cubit/detail_cubit.dart';

part 'detail_hero.dart';
part 'detail_info.dart';
part 'detail_episodes.dart';
part 'detail_sheets.dart';
part 'detail_tabs.dart';
part 'detail_skeleton.dart';

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
        seedMalId: item.malId,
        seedType: item.type,
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

  // Filler episode numbers (from Jikan by MAL id), for the "Filler" badge in the
  // episode list. Fetched once per malId; empty for non-anime / unlisted shows.
  Set<int> _fillerEps = const {};
  int? _fillerForMal;
  void _ensureFiller(int? malId) {
    if (malId == null || malId == _fillerForMal) return;
    _fillerForMal = malId;
    FillerService.instance.fillerEpisodes(malId).then((s) {
      if (mounted && s.isNotEmpty) setState(() => _fillerEps = s);
    });
  }

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

  // Tracker-driven episode grey-out: the connected tracker's watched-episode
  // count, fetched once after the detail loads (null until then / no match).
  int? _trackerProgress;

  /// Next episode to air, from the tracker entry fetched for progress. Null
  /// for a finished show, a movie, or a title with no tracker match — the row
  /// hides rather than claiming it doesn't know.
  int? _nextAiringEpisode;
  DateTime? _nextAiringAt;
  bool _trackerFetchStarted = false;

  /// Fetch the connected tracker's episode progress once, so episodes already
  /// watched on AniList/MAL/Simkl grey out even if never played in-app.
  /// Best-effort and additive — a null result changes nothing on screen.
  void _maybeFetchTrackerProgress(MediaDetail detail) {
    if (_trackerFetchStarted) return;
    _trackerFetchStarted = true;
    final hub = sl<TrackerHub>();
    if (!hub.anyConnected) return;
    final isAnime = detail.type == ProviderType.anime;
    final reading =
        detail.type == ProviderType.manga || detail.type == ProviderType.novel;
    final pins = sl<TrackerBindingStore>()
        .get(TrackerBindingStore.keyOf(widget.item.sourceId, widget.item.url));
    hub
        .fetchEntry(
          malId: detail.malId ?? widget.item.malId,
          title: (isAnime || reading) ? detail.title : null,
          tmdbId: detail.tmdbId ?? widget.item.tmdbId,
          tmdbIsTv: detail.tmdbIsTv,
          imdbId: detail.imdbId ?? widget.item.imdbId,
          pinnedIds: pins.isEmpty ? null : pins,
          kind: reading ? MediaKind.manga : MediaKind.anime,
          novel: detail.type == ProviderType.novel,
        )
        .then((e) {
      if (!mounted) return;
      // Same response the progress comes from — the airing fields were already
      // being fetched and thrown away, so showing them costs no extra request.
      // Both null for a finished show, a movie, or a title we couldn't match.
      final ep = e?.nextAiringEpisode;
      final at = e?.nextAiringAt;
      final p = e?.progress;
      if (p == null || p <= 0) {
        if (ep != null && at != null) {
          setState(() {
            _nextAiringEpisode = ep;
            _nextAiringAt = at;
          });
        }
        return;
      }
      setState(() {
        _trackerProgress = p;
        _nextAiringEpisode = ep;
        _nextAiringAt = at;
      });
    });
  }

  /// Whether the Tracking button should show for [detail]. Only when a tracker
  /// is connected AND it can actually track this title: anime/manga/novel →
  /// always (AniList/MAL resolve by malId or title regardless); movies &
  /// live-action TV → only Simkl, and only with a tmdb/imdb id to key on.
  /// Keeps the button out of the way for everyone else.
  bool _trackingAvailable(MediaDetail detail) {
    final hub = sl<TrackerHub>();
    if (!hub.anyConnected) return false;
    if (detail.type == ProviderType.anime ||
        detail.type == ProviderType.manga ||
        detail.type == ProviderType.novel) {
      return true;
    }
    final simklOn = hub.connected.any((t) => t.displayName == 'Simkl');
    final hasId = (detail.tmdbId ?? widget.item.tmdbId) != null ||
        ((detail.imdbId ?? widget.item.imdbId)?.isNotEmpty ?? false);
    return simklOn && hasId;
  }

  /// Open the tracker sync sheet — status, score and episode/chapter
  /// progress in one place, applied to every connected tracker at once. Anime
  /// resolves by MAL id or title; movies/TV via Simkl's tmdb/imdb id; manga/
  /// novel resolves by malId or title too (AniList/MAL manga lists). The
  /// sheet returns the applied progress so grey-out can update immediately.
  Future<void> _openTrackingSheet(MediaDetail detail) async {
    final reading = detail.type == ProviderType.manga ||
        detail.type == ProviderType.novel;
    final applied = await showTrackerSyncSheet(
      context,
      title: detail.title,
      isAnime: detail.type == ProviderType.anime,
      reading: reading,
      malId: detail.malId ?? widget.item.malId,
      tmdbId: detail.tmdbId ?? widget.item.tmdbId,
      tmdbIsTv: detail.tmdbIsTv,
      imdbId: detail.imdbId ?? widget.item.imdbId,
      bindingKey: TrackerBindingStore.keyOf(
        widget.item.sourceId,
        widget.item.url,
      ),
    );
    if (applied != null && mounted && applied > (_trackerProgress ?? 0)) {
      setState(() => _trackerProgress = applied);
    }
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

  /// Best-effort web URL for the title. Absolute item URLs (CloudStream/JS)
  /// pass through; Aniyomi items store a relative path, so join it onto the
  /// source's base site (mirroring the native `baseUrl + anime.url`).
  String? _sourceWebUrl() {
    final u = widget.item.url.trim();
    if (u.isEmpty) return null;
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    final base = sl<SourceRepository>().baseUrlFor(widget.item.sourceId).trim();
    if (base.isEmpty) return null;
    if (base.endsWith('/') && u.startsWith('/')) return base + u.substring(1);
    return base + u;
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

  /// Resolve every mirror for an episode, behind a blocking spinner.
  ///
  /// Deliberately not the fast path. Fast returns on the first usable link and
  /// leaves the rest resolving in the background, so a chooser built from it
  /// often shows one server out of several — you'd be picking from a list that
  /// isn't finished. Waiting costs a few seconds and shows the real choice.
  Future<List<VideoSource>> _resolveWithProgress(Episode ep) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      return await sl<SourceRepository>().sources(
        ep.url,
        sourceId: widget.item.sourceId,
        fast: false,
      );
    } catch (_) {
      // A dead source shouldn't leave a spinner on screen; the caller reports
      // the empty result as "no sources found".
      return const [];
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  /// Push a manual watched mark out to whichever trackers are connected.
  ///
  /// Only whole episode numbers: tracker progress is an integer, so a "12.5"
  /// recap or special would either round into a real episode or be rejected.
  /// Same fan-out the player uses when you finish an episode normally.
  Future<void> _scrobbleUpTo(Episode ep, MediaDetail detail) async {
    final n = ep.number;
    if (n == null || n <= 0 || n != n.truncateToDouble()) return;
    await sl<TrackerHub>().scrobble(
      malId: detail.malId ?? widget.item.malId,
      title: detail.type == ProviderType.anime ? detail.title : null,
      tmdbId: widget.item.tmdbId,
      tmdbIsTv: widget.item.tmdbIsTv,
      imdbId: widget.item.imdbId,
      episode: n.toInt(),
      // Asked for by hand, so it goes out even with auto-tracking off.
      auto: false,
    );
  }

  /// Long-press an episode → choose where it plays, this once. Settings keeps
  /// owning the standing default, so trying VLC on one episode doesn't quietly
  /// rewire every later tap. Dismissing plays nothing — a long-press that
  /// started playback on its own would be a trap.
  Future<void> _pickPlayerFor(
    List<Episode> episodes,
    int index,
    MediaDetail detail,
    String category,
  ) async {
    if (index < 0 || index >= episodes.length) return;
    final ep = episodes[index];
    final label = ep.title.trim().isNotEmpty
        ? ep.title.trim()
        : 'Episode ${ep.number?.toInt() ?? index + 1}';
    final prefs = sl<PlaybackPrefs>();

    final resume = sl<ResumeStore>();
    final hub = sl<TrackerHub>();
    final action = await showEpisodeActionSheet(
      context,
      episodeLabel: label,
      currentPlayerLabel: prefs.externalPlayerPackage.isEmpty
          ? 'Built-in'
          : (prefs.externalPlayerLabel.isEmpty
                ? 'External'
                : prefs.externalPlayerLabel),
      isWatched:
          resume.get(widget.item.sourceId, widget.item.url, ep.id)?.finished ??
          false,
      tracksToServices: hub.anyConnected,
    );
    if (action == null || !mounted) return;

    switch (action) {
      case EpisodeAction.pickPlayer:
        final choice = await showEpisodePlayerSheet(
          context,
          episodeLabel: label,
          defaultPackage: prefs.externalPlayerPackage,
        );
        if (choice == null || !mounted) return;
        await _openPlayer(
          episodes,
          index,
          detail,
          category,
          playerOverride: choice,
        );
      case EpisodeAction.reloadLinks:
        // Drop the prefetch too, or the next fast resolve consumes it before
        // it ever looks at the resolved cache and hands back the same dead
        // links — the reload would look like it did nothing.
        sl<SourceRepository>().invalidateSources(
          ep.url,
          sourceId: widget.item.sourceId,
          includePrefetch: true,
        );
        // Deliberately no playback: you reload because the links died, and the
        // next thing you usually want is a different mirror. Auto-playing
        // takes that choice away and tends to fail again on the same source.
        // Re-primes in the background so the play you do make is still quick.
        sl<SourceRepository>().prefetch(
          ep.url,
          sourceId: widget.item.sourceId,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Links reloaded')));

      case EpisodeAction.playMirror:
        // Scraping takes seconds, unlike every other row here, so the wait is
        // shown rather than left as a dead long-press.
        final sources = await _resolveWithProgress(ep);
        if (!mounted) return;
        if (sources.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No sources found for this episode')),
          );
          return;
        }
        final picked = await showMirrorSheet(
          context,
          episodeLabel: label,
          sources: sources,
        );
        if (picked == null || !mounted) return;
        // The pick applies to this episode and nothing else — no label saved.
        // Remembering it meant re-finding the mirror by label on the next
        // open, and when that list came back without it the language fallback
        // quietly started a different server: pick vidplay, get vidstream.
        // Choosing again per episode is the honest trade.
        await _openPlayer(
          episodes,
          index,
          detail,
          category,
          initialSource: picked,
        );

      case EpisodeAction.toggleWatched:
        final nowWatched =
            !(resume
                    .get(widget.item.sourceId, widget.item.url, ep.id)
                    ?.finished ??
                false);
        await resume.setWatched(
          widget.item.sourceId,
          widget.item.url,
          ep.id,
          watched: nowWatched,
        );
        // Only forward when marking. Trackers store a high-water mark, not a
        // set, so there's no "unwatch episode 12" to send — dropping progress
        // back would be a guess at what the user wanted their list to say.
        if (nowWatched) await _scrobbleUpTo(ep, detail);
        if (!mounted) return;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(nowWatched ? 'Marked as watched' : 'Marked unwatched'),
          ),
        );

      case EpisodeAction.markAboveWatched:
        // Everything up to and including the one held: you came back
        // mid-season and want the backlog cleared, and excluding the episode
        // you pressed would mean marking it separately every time.
        for (var i = 0; i <= index; i++) {
          await resume.setWatched(
            widget.item.sourceId,
            widget.item.url,
            episodes[i].id,
            watched: true,
          );
        }
        // One tracker write for the highest episode, not one per episode —
        // progress is a high-water mark, so the rest are implied and firing
        // twelve updates would just rate-limit the account.
        await _scrobbleUpTo(ep, detail);
        if (!mounted) return;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Marked ${index + 1} episodes as watched')),
        );
    }
  }

  Future<void> _openPlayer(
    List<Episode> episodes,
    int index,
    MediaDetail detail,
    String category, {
    /// Set only by the long-press sheet: play this one episode in this player,
    /// ignoring the Settings default. Null keeps the existing behaviour.
    PlayerChoice? playerOverride,

    /// A mirror picked from the long-press menu, opened instead of the
    /// adaptive default. One-shot — the cubit clears it after this episode.
    VideoSource? initialSource,
  }) async {
    // Reading types never touch the player — route to the reader instead.
    // Both tap paths (Play button + episode-row onTap) call this same
    // function, so gating it here covers both in one place. Safety-critical:
    // a manga/novel title must never try to resolve video sources. Checks
    // BOTH the loaded detail's type and the search-result item's type —
    // provider JSON isn't normalized, so a source that disagrees between the
    // two still can't reach the player.
    final t = detail.type;
    final it = widget.item.type;
    if (t == ProviderType.novel ||
        t == ProviderType.manga ||
        it == ProviderType.novel ||
        it == ProviderType.manga) {
      // Same auto-add as the video path below — reading titles route out
      // through this early return, so without this they never got it.
      if (sl<PlaybackPrefs>().autoAddToMyList &&
          !IncognitoMode.on &&
          !_myList.contains(widget.item)) {
        _myList.add(widget.item);
        _listStatus.setStatus(widget.item, WatchStatus.watching);
      }
      _openReader(episodes, index, detail);
      return;
    }

    // Auto-add this title to My List (as Watching) on play, if the user opted
    // in — mirrors the tracker auto-scrobble. Skipped in incognito and when it's
    // already listed; fire-and-forget so it never delays playback.
    if (sl<PlaybackPrefs>().autoAddToMyList &&
        !IncognitoMode.on &&
        !_myList.contains(widget.item)) {
      _myList.add(widget.item);
      _listStatus.setStatus(widget.item, WatchStatus.watching);
    }

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

    // Scrobble ids. A movie-typed title from a movie source (e.g. MovieBox) may
    // actually be anime — resolve its MAL id here so AniList/MAL scrobble. We
    // await the detail's in-flight promotion (started on load); if Play beat it,
    // resolve inline. Best-effort — a miss just leaves it a movie.
    var malId = detail.malId ?? widget.item.malId;
    var scrobbleTitle =
        detail.type == ProviderType.anime ? detail.title : null;
    if (malId == null && detail.type == ProviderType.movie) {
      try {
        final promoted = await (context.read<DetailCubit>().animePromotion ??
            sl<MetadataEnrichment>().promoteMovieToAnimeMalId(detail));
        if (promoted != null) {
          malId = promoted;
          scrobbleTitle = detail.title;
        }
      } catch (_) {/* leave as a movie */}
    }
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          playerOverride: playerOverride?.package,
          initialSource: initialSource,
          sourceId: widget.item.sourceId,
          episodes: episodes,
          startIndex: index,
          resume: sl<ResumeStore>(),
          resolveSources: (u) => sl<SourceRepository>().sources(
            u,
            sourceId: widget.item.sourceId,
            fast: true,
          ),
          // The resolve above returns on the first usable link so playback
          // starts fast; the remaining mirrors keep resolving natively. This
          // lets the Sources sheet pick them up once they land.
          pollSources: (u) => sl<SourceRepository>().polledSources(
            u,
            sourceId: widget.item.sourceId,
          ),
          history: sl<WatchHistory>(),
          showTitle: detail.title,
          cover: detail.cover ?? widget.item.cover,
          coverHeaders: detail.coverHeaders ?? widget.item.coverHeaders,
          showUrl: widget.item.url,
          category: launchCategory,
          malId: malId,
          scrobbleTitle: scrobbleTitle,
          tmdbId: detail.tmdbId ?? widget.item.tmdbId,
          tmdbIsTv: detail.tmdbIsTv,
          imdbId: detail.imdbId ?? widget.item.imdbId,
          availableCategories: availableCategories,
        ),
      ),
    );
  }

  /// Routes a reading-type title (manga/novel) to its reader instead of the
  /// player. [chapters] mirrors [_openPlayer]'s `episodes` list; [index] is
  /// the tapped/resume chapter. Prefers `detail.type`; falls back to
  /// `widget.item.type` for the disagreeing-provider-JSON case the guard
  /// above also covers, so a mismatch still lands on the right reader
  /// instead of silently doing nothing.
  void _openReader(List<Episode> chapters, int index, MediaDetail detail) {
    final readingType =
        (detail.type == ProviderType.novel || detail.type == ProviderType.manga)
        ? detail.type
        : widget.item.type;
    switch (readingType) {
      case ProviderType.novel:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NovelReaderScreen(
              sourceId: widget.item.sourceId,
              showId: widget.item.id,
              showTitle: detail.title,
              cover: detail.cover ?? widget.item.cover,
              chapters: chapters,
              startIndex: index,
              malId: detail.malId ?? widget.item.malId,
            ),
          ),
        );
        return;
      case ProviderType.manga:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MangaReaderScreen(
              sourceId: widget.item.sourceId,
              showId: widget.item.id,
              showTitle: detail.title,
              cover: detail.cover ?? widget.item.cover,
              chapters: chapters,
              startIndex: index,
              malId: detail.malId ?? widget.item.malId,
            ),
          ),
        );
        return;
      case ProviderType.anime:
      case ProviderType.movie:
        return; // unreachable — _openPlayer only calls this for reading types
    }
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

  /// Which episode Play opens, and whether that reads as "Continue". Local
  /// playback wins when present (unchanged behaviour); with NO local marks it
  /// falls back to the connected tracker's watched count — resume the first
  /// episode beyond it — so a title you've only progressed on AniList/MAL/Simkl
  /// still says "Continue". Single-season only, same limit as the grey-out.
  ({int index, bool hasResume}) _resumeTarget(List<Episode> eps) {
    if (eps.isEmpty) return (index: 0, hasResume: false);
    final store = sl<ResumeStore>();
    final hasLocal = eps.any(
      (e) => store.get(widget.item.sourceId, widget.item.url, e.id) != null,
    );
    if (hasLocal) return (index: _resumeIndex(eps), hasResume: true);
    final p = _trackerProgress;
    if (p != null && p > 0 && seasonsOf(eps).length <= 1) {
      for (var j = 0; j < eps.length; j++) {
        final n = eps[j].number?.toInt();
        if (n != null && n > p) return (index: j, hasResume: true);
      }
    }
    return (index: 0, hasResume: false);
  }

  /// Reading counterpart of [_resumeTarget]: walks the chapters for the
  /// highest one carrying a saved reading position (per-chapter, from
  /// [ReadStore] — the reader's own scroll/page progress), advancing past it
  /// once it's finished — same rule [_resumeIndex] applies to video resume
  /// marks. Keyed the same way [NovelReaderScreen] saves them: showId is
  /// [MediaItem.id], not the show url (see `_openReader`).
  ///
  /// With NO local mark (e.g. this device never opened a chapter, or the
  /// reader's per-chapter position was never saved) it falls back to
  /// [ReadHistory] — the cloud-synced last-read chapter — the same way
  /// [_resumeTarget] falls back to the tracker's watched count for video.
  /// Only when both come up empty does this say "start over" (chapter 0).
  ({int index, bool hasResume}) _readResumeIndex(List<Episode> chapters) {
    if (chapters.isEmpty) return (index: 0, hasResume: false);
    final store = sl<ReadStore>();
    int? highestMarked;
    for (var j = 0; j < chapters.length; j++) {
      if (store.get(widget.item.sourceId, widget.item.id, chapters[j].id) !=
          null) {
        highestMarked = j;
      }
    }
    if (highestMarked != null) {
      if (!store.finished(
        widget.item.sourceId,
        widget.item.id,
        chapters[highestMarked].id,
      )) {
        return (index: highestMarked, hasResume: true);
      }
      final next = highestMarked + 1 < chapters.length
          ? highestMarked + 1
          : highestMarked;
      return (index: next, hasResume: true);
    }
    final entry = sl<ReadHistory>().get(widget.item.sourceId, widget.item.id);
    if (entry != null) {
      var idx = chapters.indexWhere((c) => c.id == entry.chapterId);
      if (idx < 0) idx = chapters.indexWhere((c) => c.url == entry.chapterUrl);
      if (idx >= 0) {
        if (entry.finished && idx + 1 < chapters.length) idx += 1;
        return (index: idx, hasResume: true);
      }
    }
    return (index: 0, hasResume: false);
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
            // Phone-only Minimal wheel (Settings → Interface). TV stays on the
            // well-tested Classic grid regardless of the pref.
            minimal:
                !sl<AppMode>().isTv &&
                sl<PlaybackPrefs>().batchDownloadStyle == 'minimal',
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
    // Best-effort per-episode descriptions on a category switch. Prefer the
    // cubit's resolved detail (promoted malId for movie-source anime).
    var eps = d.episodes;
    if (mounted) {
      final cd = context.read<DetailCubit>().state.detail ?? d;
      eps = await sl<EpisodeMetadataService>().enrich(
        episodes: eps,
        type: cd.type,
        malId: cd.malId,
        tmdbId: cd.tmdbId,
        tmdbIsTv: cd.tmdbIsTv,
      );
    }
    final byS = <int, List<Episode>>{};
    for (final e in eps) {
      (byS[seasonOf(e) ?? 1] ??= <Episode>[]).add(e);
    }
    if (byS.isEmpty) byS[1] = eps;
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
    // Manga/novel: no player, no sub/dub, no video downloads — drives the
    // Play→Read relabel and hides the download affordances below.
    final isReading =
        detail.type == ProviderType.novel || detail.type == ProviderType.manga;
    // Kick the (cached, once-per-malId) filler lookup for the "Filler" badge.
    _ensureFiller(detail.malId ?? item.malId);
    // Kick the (once-per-detail) tracker-progress lookup for grey-out.
    _maybeFetchTrackerProgress(detail);

    // Resume / play button logic. Local playback first; else fall back to the
    // tracker's watched count (see _resumeTarget). Local case is unchanged.
    // Reading titles use their OWN progress store instead — _resumeTarget's
    // ResumeStore never carries a mark for a chapter, so it would always
    // (harmlessly but wrongly) say "start over".
    final resume = _resumeTarget(eps);
    final readResume = isReading ? _readResumeIndex(eps) : null;
    final resumeIdx = isReading ? readResume!.index : resume.index;
    // Warm the stream for the episode Play will start, in the background, so
    // tapping Play is near-instant. Deferred to after this frame so it can't
    // affect the detail screen's rendering/scroll. Skipped for reading types
    // — prefetch resolves VIDEO sources, and merely opening a manga/novel
    // detail must never fire that against a chapter URL.
    if (!isReading && eps.isNotEmpty) {
      _maybePrefetch(eps[resumeIdx].url, item.sourceId);
    }
    final hasAnyMark = eps.any(
      (e) => store.get(item.sourceId, item.url, e.id) != null,
    );
    final episodeNum = eps.isNotEmpty
        ? (eps[resumeIdx].number?.toInt() ?? resumeIdx + 1)
        : 1;
    final buttonLabel = isReading
        ? (readResume!.hasResume ? 'Continue' : 'Read')
        : (resume.hasResume ? 'Continue E$episodeNum' : 'Play');

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
        ? eps.where((e) => seasonOf(e) == currentSeason).toList()
        : eps;

    // Episodes grouped by season for the download sheet's season chips.
    final episodesBySeason = <int, List<Episode>>{};
    if (hasMultipleSeasons) {
      for (final e in eps) {
        (episodesBySeason[seasonOf(e) ?? 1] ??= <Episode>[]).add(e);
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
      // Manga/novel count chapters. The model stays `Episode`; this is the
      // user-facing word only, so anime/movie reads exactly as before.
      final unit = isReading ? 'Chapter' : 'Episode';
      metaParts.add('${eps.length} $unit${eps.length == 1 ? '' : 's'}');
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
                  icon: isReading
                      ? Icons.menu_book_rounded
                      : Icons.play_arrow_rounded,
                  onPressed: eps.isNotEmpty
                      ? () => _openPlayer(eps, resumeIdx, detail, category)
                      : null,
                ),
                // Reading downloads are out of scope for this plan.
                if (!isReading) ...[
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
                  // Reading-aware: a manga on your list is "Reading", not
                  // "Watching". Display only — the stored status is still
                  // WatchStatus.watching, so My List and the trackers are
                  // untouched, and reading:false returns the plain label
                  // unchanged for anime.
                  label: _status == null
                      ? 'My List'
                      : shortLabelFor(_status!, reading: isReading),
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
                if (_trackingAvailable(detail))
                  _IconAction(
                    icon: Icons.sync_rounded,
                    label: 'Tracking',
                    tooltip: 'Sync status, score & progress',
                    onTap: () => _openTrackingSheet(detail),
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
                // Bottom inset lifts the line toward the label. A Tab is 46
                // high for 15px text, so the indicator otherwise draws at the
                // bottom of that box with a visible gap under the word.
                // Raising the line rather than shortening the tab keeps the
                // tap target at its full height.
                insets: EdgeInsets.only(left: 2, right: 2, bottom: 8),
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
              tabs: [
                Tab(text: isReading ? 'Chapters' : 'Episodes'),
                const Tab(text: 'Cast'),
                const Tab(text: 'Relations'),
                const Tab(text: 'Details'),
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
            fillerEps: _fillerEps,
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
            trackerProgress: _trackerProgress,
            nextAiringEpisode: _nextAiringEpisode,
            nextAiringAt: _nextAiringAt,
            onOpen: (fullIndex) =>
                _openPlayer(eps, fullIndex, detail, category),
            // Reading types resolve to a reader, so there's no player to pick.
            onPickPlayer: isReading
                ? null
                : (fullIndex) =>
                      _pickPlayerFor(eps, fullIndex, detail, category),
            onRefresh: cubit.refresh,
            onDownload: (ep) => _downloadSingle(ep, detail, category),
            showDownload: !isReading,
            isReading: isReading,
          ),
          // ── Cast ────────────────────────────────────────────────────────────
          _CastTab(
            cast: state.cast.isNotEmpty
                ? state.cast
                : [for (final n in detail.cast) CastMember(name: n)],
            onOpenPerson: (ref) => Navigator.of(
              context,
            ).push(PersonPage.route(ref, sourceId: widget.item.sourceId)),
          ),
          // ── Relations ─────────────────────────────────────────────────────────
          _RelationsTab(relations: state.relations, onOpen: _openRelation),
          // ── Details ──────────────────────────────────────────────────────────
          _DetailsTab(
            sourceName: sourceName,
            statusStr: statusStr,
            reading: isReading,
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
