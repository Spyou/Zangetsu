import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/app_mode.dart';
import '../../core/aniyomi/aniyomi_image_provider.dart';
import '../../core/di/injector.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/mihon/mihon_image_provider.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/notify/notification_service.dart';
import '../../core/update/extension_auto_updater.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/models/episode.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/reading/read_history.dart';
import '../../core/repository/source_repository.dart';
import '../../core/privacy/incognito_mode.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/announce/announcement.dart';
import '../announce/announcement_sheet.dart';
import '../community/community_sheet.dart';
import '../notify/subscriptions_screen.dart';
import '../reader/manga_reader_screen.dart';
import '../reader/novel_reader_screen.dart';
import '../sources/aniyomi_repo_tab.dart' show kAniyomiReposBoxName;
import '../sources/providers_hub_screen.dart';
import '../sources/zangetsu_sources_screen.dart';
import '../update/update_dialog.dart';
import 'continue_section.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/featured_carousel.dart';
import '../../core/ui/featured_hero.dart';
import '../../core/metadata/title_logo_service.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/media_info_sheet.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/row_skeleton.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/ui/states.dart';
import '../auth/auth_cubit.dart';
import '../auth/reconnect.dart';
import '../detail/detail_screen.dart';
import '../history/history_screen.dart';
import '../player/player_screen.dart';
import 'cubit/home_cubit.dart';
import 'home_screen_tv.dart';
import 'see_all_screen.dart';

/// Provides the [HomeCubit] (which owns the three browse rows + the carousel's
/// trending source) and kicks off the first load. The view itself stays
/// Stateful for the per-item lazy hero-description cache and the navigation
/// helpers.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Use the shared singleton so the splash can warm it before this mounts.
    return BlocProvider.value(value: sl<HomeCubit>(), child: const _HomeView());
  }
}

class _HomeView extends StatefulWidget {
  const _HomeView();

  @override
  State<_HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<_HomeView>
    with SingleTickerProviderStateMixin {
  final _repo = sl<SourceRepository>();
  final _myList = sl<MyListStore>();

  /// Hero metadata cache: key = "sourceId:id". Futures are stored so they're
  /// never re-fetched on carousel rotation; pre-warmed when hero items load.
  final Map<String, Future<HeroMeta?>> _metaCache = {};
  bool _heroPrewarmed = false;

  // ── Logo-strike mode transition ──────────────────────────────────────────
  // Tapping a mode card runs a full-screen overlay: the Zangetsu mark springs
  // in at centre behind a scrim, a red glow pulses and a steel glint sweeps the
  // blade, the mode swaps hidden at that peak, then it reveals. Self-contained —
  // see [_enterMode] / [_slashOverlay].
  late final AnimationController _slashCtrl;
  bool _slashing = false;
  bool _slashSwapped = false;
  ContentMode? _slashTarget;

  // Auto update-check runs at most once per app process (not on every rebuild
  // or tab revisit). Static so it survives this widget being recreated.
  static bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    // Swap the content mode at the slash's peak (hidden behind the scrim), then
    // tear the overlay down once it finishes.
    _slashCtrl =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 600),
          )
          ..addListener(() {
            if (!_slashSwapped &&
                _slashTarget != null &&
                _slashCtrl.value >= 0.5) {
              _slashSwapped = true;
              sl<ContentModeCubit>().setMode(_slashTarget!);
            }
          })
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && mounted) {
              setState(() {
                _slashing = false;
                _slashTarget = null;
              });
            }
          });
    // The splash usually pre-warms the rows; only fetch here if it didn't
    // (e.g. first run right after onboarding, or a source with no warm yet).
    final cubit = context.read<HomeCubit>();
    if (cubit.state.sections == null && !cubit.state.loading) cubit.load();
    // Silently check GitHub Releases once on launch; the dialog only appears if
    // a newer, non-skipped version exists. Best-effort — never blocks startup.
    if (!_updateChecked) {
      _updateChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await maybeShowUpdateDialog(context);
        // One-time community welcome (its own flag, independent of the per-id
        // announcement feed), then any new developer announcement — all awaited
        // in sequence so the modals never fight over the stack.
        if (mounted) await maybeShowCommunitySheet(context);
        if (mounted) await maybeShowAnnouncement(context);
      });
      _checkSourceUpdates();
    }
  }

  @override
  void dispose() {
    _slashCtrl.dispose();
    super.dispose();
  }

  /// Best-effort, non-blocking check for CloudStream source updates on launch.
  /// READ-ONLY (re-fetches catalogs, downloads nothing); posts a notification
  /// when updates exist and the user left that toggle on. Deferred a few seconds
  /// so it never competes with first content load, and fully guarded so it can
  /// NEVER affect startup or playback.
  Future<void> _checkSourceUpdates() async {
    final prefs = sl<PlaybackPrefs>();
    final autoUpdate = prefs.autoUpdateExtensions;
    // The read-only notify path below is Android-only; keep that gate unless
    // we're auto-updating (JS providers auto-update on any platform).
    if (!autoUpdate && !Platform.isAndroid) return;
    await Future<void>.delayed(const Duration(seconds: 4));
    if (!mounted) return;

    // Auto-update path: apply updates across all ecosystems, throttled to
    // ~once a day across launches. Best-effort — never touches startup.
    if (autoUpdate) {
      final now = DateTime.now().millisecondsSinceEpoch;
      const dayMs = 24 * 60 * 60 * 1000;
      if (now - prefs.lastExtensionUpdateMs < dayMs) return;
      await prefs.setLastExtensionUpdateMs(now);
      final updated = await ExtensionAutoUpdater.run();
      if (updated > 0) {
        await NotificationService.instance.showMessage(
          id: 779100,
          title: 'Extensions updated',
          body:
              '$updated extension${updated == 1 ? '' : 's'} updated to the latest version.',
        );
      }
      return;
    }

    try {
      final csManager = sl<CloudStreamManager>();
      final csCount = await csManager.checkAllUpdates();

      var aniCount = 0;
      try {
        final repoUrls = Hive.isBoxOpen(kAniyomiReposBoxName)
            ? Hive.box<String>(kAniyomiReposBoxName).values.toList()
            : const <String>[];
        if (repoUrls.isNotEmpty) {
          aniCount = await sl<AniyomiManager>().checkAllUpdates(repoUrls);
        }
      } catch (_) {
        /* aniyomi check must never break the CS check or startup */
      }

      final total = csCount + aniCount;
      if (total > 0 && csManager.notifyUpdates) {
        await NotificationService.instance.showSourceUpdates(count: total);
      }
    } catch (_) {
      /* never affects startup */
    }
  }

  /// Genres + episode count for the hero banner (lazily fetched, cached).
  Future<HeroMeta?> _heroMeta(MediaItem m) =>
      _metaCache.putIfAbsent('${m.sourceId}:${m.id}', () async {
        final d = await _detailOf(m.url, m.sourceId);
        if (d == null) return null;
        return HeroMeta(
          genres: d.genres,
          episodeCount: d.episodes.length,
          year: d.year,
        );
      });

  /// Warm ONLY the first hero's metadata (the slide shown first). The rest load
  /// lazily, one at a time, as the carousel rotates — each via the hero's own
  /// `FutureBuilder` on [_heroMeta] (cached). Firing ALL of them up front fired
  /// one `detail()` per hero AT ONCE; for a heavy CloudStream source (e.g.
  /// MovieBox) those N concurrent `load()`s saturated the read pool and froze
  /// the UI thread → ANR. One-at-a-time on rotation is fine even for MovieBox.
  void _prewarmHeroMeta(List<MediaItem> items) {
    if (_heroPrewarmed || items.isEmpty) return;
    _heroPrewarmed = true;
    _heroMeta(items.first);
    // Warm the TMDB title logos for the whole carousel up front. The service
    // resolves them SEQUENTIALLY (so no request burst at TMDB) and caches both
    // in memory and on disk — so each logo is ready before its banner rotates
    // in (no pop-in), and it barely touches TMDB on later launches.
    sl<TitleLogoService>().prefetch(items);
  }

  void _openDetail(MediaItem item) {
    Navigator.push(context, DetailScreen.route(item)).then((_) {
      // Refresh Continue Watching + My List row when returning from detail.
      if (mounted) setState(() {});
    });
  }

  String _typeLabel(ProviderType t) =>
      t == ProviderType.movie ? 'Movie' : 'Anime';

  Future<MediaDetail?> _detailOf(String url, String sourceId) async {
    try {
      return await _repo.detail(url, sourceId: sourceId);
    } catch (_) {
      return null;
    }
  }

  /// Netflix-style long-press info card for a browse-row item.
  void _showInfo(MediaItem item) {
    showMediaInfoSheet(
      context,
      title: item.title,
      englishTitle: item.englishTitle,
      cover: item.cover,
      headers: item.coverHeaders,
      typeLabel: _typeLabel(item.type),
      subCount: item.subCount,
      dubCount: item.dubCount,
      detail: _detailOf(item.url, item.sourceId),
      inMyList: _myList.contains(item),
      onPlay: () => _playFeatured(item),
      onOpenDetail: () => _openDetail(item),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: item,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(item);
      },
    );
  }

  /// Long-press info card for a Continue Watching item — adds Resume + Remove.
  void _showContinueInfo(HistoryEntry e) {
    final stub = MediaItem(
      id: e.showId,
      title: e.showTitle,
      cover: e.cover,
      coverHeaders: e.coverHeaders,
      url: e.showUrl,
      type: ProviderType.anime,
      sourceId: e.sourceId,
    );
    final pct = (e.progress * 100).round();
    showMediaInfoSheet(
      context,
      title: e.showTitle,
      cover: e.cover,
      headers: e.coverHeaders,
      detail: _detailOf(e.showUrl, e.sourceId),
      inMyList: _myList.contains(stub),
      playLabel: 'Resume',
      progress: e.progress,
      progressLabel: e.episodeNumber != null
          ? 'Episode ${e.episodeNumber!.toInt()} · $pct% watched'
          : '$pct% watched',
      onPlay: () => _resume(e),
      onOpenDetail: () => _openDetail(stub),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: stub,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(stub);
      },
      onRemoveFromContinue: () async {
        await sl<WatchHistory>().remove(e.sourceId, e.showId);
        if (mounted) setState(() {});
      },
    );
  }

  /// Long-press info card for a Continue Reading item — the manga/novel twin of
  /// [_showContinueInfo]: Read + Remove + My List, backed by [ReadHistory].
  void _showContinueReadingInfo(ReadEntry e) {
    final stub = MediaItem(
      id: e.showId,
      title: e.title,
      cover: e.cover,
      url: e.showId,
      type: e.type,
      sourceId: e.sourceId,
    );
    final pct = e.total > 0 ? ((e.pos / e.total) * 100).round() : 0;
    final progress = e.total > 0 ? (e.pos / e.total).clamp(0.0, 1.0) : 0.0;
    showMediaInfoSheet(
      context,
      title: e.title,
      cover: e.cover,
      detail: _detailOf(e.showId, e.sourceId),
      inMyList: _myList.contains(stub),
      playLabel: 'Read',
      progress: progress,
      progressLabel: e.chapterNumber != null
          ? 'Chapter ${e.chapterNumber!.toInt()} · $pct% read'
          : '$pct% read',
      onPlay: () => _resumeReading(e),
      onOpenDetail: () => _openDetail(stub),
      onToggleMyList: () async {
        await showListStatusSheet(
          context,
          item: stub,
          onChanged: () {
            if (mounted) setState(() {});
          },
        );
        return _myList.contains(stub);
      },
      onRemoveFromContinue: () async {
        await sl<ReadHistory>().remove(e.sourceId, e.showId);
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _playFeatured(MediaItem item) async {
    // Manga/novel: the hero's primary action says "Read", so it must not drop
    // into the video player. Route to the title instead — Detail owns the real
    // Read button, which resolves the chapter list, picks up the saved reading
    // position and routes manga vs novel to the right reader. Duplicating that
    // here would mean re-implementing chapter resolution on Home.
    if (sl<ContentModeCubit>().state.isReading) {
      _openDetail(item);
      return;
    }
    // Fresh play: prefer a saved per-title sub/dub choice, else the global
    // default category, else 'sub'.
    final category =
        sl<TitlePrefsStore>().category(item.sourceId, item.url) ??
        sl<PlaybackPrefs>().defaultCategory;
    // Instant nav — the player resolves the episode list behind its loader.
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          sourceId: item.sourceId,
          episodesResolver: () =>
              _repo.episodes(item.url, sourceId: item.sourceId),
          resume: sl<ResumeStore>(),
          resolveSources: (u) =>
              _repo.sources(u, sourceId: item.sourceId, fast: true),
          history: sl<WatchHistory>(),
          showTitle: item.title,
          cover: item.cover,
          coverHeaders: item.coverHeaders,
          showUrl: item.url,
          category: category,
          malId: item.malId,
          scrobbleTitle: item.type == ProviderType.anime ? item.title : null,
          tmdbId: item.tmdbId,
          tmdbIsTv: item.tmdbIsTv,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Resume from Continue Watching. Navigates to the player INSTANTLY; the
  /// player resolves the episode list behind its own branded loader (no blocking
  /// pre-navigation spinner).
  Future<void> _resume(HistoryEntry e) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          sourceId: e.sourceId,
          episodesResolver: () => _repo.episodes(
            e.showUrl,
            category: e.category,
            sourceId: e.sourceId,
          ),
          resumeEpisodeId: e.episodeId,
          resumeEpisodeNumber: e.episodeNumber,
          resumePosition: e.position,
          resume: sl<ResumeStore>(),
          resolveSources: (u) =>
              _repo.sources(u, sourceId: e.sourceId, fast: true),
          history: sl<WatchHistory>(),
          showTitle: e.showTitle,
          cover: e.cover,
          coverHeaders: e.coverHeaders,
          showUrl: e.showUrl,
          category: e.category,
          malId: e.malId,
          scrobbleTitle: e.malId != null ? e.showTitle : null,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// Resume from Continue Reading. [ReadEntry] only carries the last-read
  /// CHAPTER's own url (not the show's page url — unlike [HistoryEntry],
  /// which has both), so this can't re-resolve the show's full chapter list
  /// up front the way [_resume] does for video. It reopens exactly that one
  /// chapter at its saved scroll position (restored by the reader itself via
  /// ReadStore) and passes `resolveChapters: true` — the reader fetches the
  /// full list itself in the background and lights up prev/next once it
  /// lands, without touching the chapter already on screen.
  ///
  /// Routes to [MangaReaderScreen] or [NovelReaderScreen] by [ReadEntry.type]
  /// — see [readerFor]. [ReadEntry] has no malId of its own (it's populated
  /// from the tapped MediaItem/detail at read-start, same as WatchHistory's
  /// scrobbleTitle path), so a resumed session still can't scrobble; that's
  /// an existing gap, not something this resume path can close on its own.
  Future<void> _resumeReading(ReadEntry e) async {
    final chapter = Episode(
      id: e.chapterId,
      title: e.chapterNumber != null
          ? 'Chapter ${e.chapterNumber!.toInt()}'
          : 'Chapter',
      number: e.chapterNumber,
      url: e.chapterUrl,
    );
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => readerFor(e, chapter)),
    );
    if (mounted) setState(() {});
  }

  /// Row entrance is now handled per-item by [RevealItem] (the cascade
  /// cascade). This wrapper used to fade the whole row in, which MASKED that
  /// cascade — so it's now a passthrough, kept only so its call sites are
  /// untouched. Returns [child] unchanged.
  Widget _animated(Widget child) => child;

  /// Floating brand header — always positioned on top of the hero or bg.
  Widget _buildHeader() {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            // Brand wordmark — the actual logo lettering (exact font).
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Image.asset(
                  'assets/icon/wordmark.png',
                  height: 22,
                  fit: BoxFit.contain,
                ),
              ),
            ),
            // Incognito indicator — visible only while on; tap to exit.
            ValueListenableBuilder<bool>(
              valueListenable: IncognitoMode.notifier,
              builder: (_, on, _) => on
                  ? GestureDetector(
                      onTap: () => IncognitoMode.set(false),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surface2,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppColors.hairline),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.visibility_off_rounded,
                              size: 13,
                              color: AppColors.textSecondary,
                            ),
                            SizedBox(width: 5),
                            Text(
                              'Incognito',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            // Header bell is parked for now (design TBD) — re-add
            // `_notificationBell(context)` here once one is chosen.
            BlocBuilder<ActiveSourceCubit, String>(
              builder: (context, id) => SourceSwitcher(
                currentId: id,
                onChanged: (newId) =>
                    context.read<ActiveSourceCubit>().setSource(newId),
                onInstallSources: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const ZangetsuSourcesScreen(openToRepos: true),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Flat bell → Notifications screen. The accent dot shows while any
  /// announcement is unseen and clears itself reactively (the screen calls
  /// markAllSeen, the Hive box updates, the listenable rebuilds).
  ///
  /// Currently unwired — the header bell is parked until a design is chosen
  /// (mockups in docs/mockups/bell-options.html).
  // ignore: unused_element
  Widget _notificationBell(BuildContext context) {
    // Built fresh inside the listenable's builder — a captured widget
    // instance would be canonical and the rebuild would be skipped.
    Widget bell() => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SubscriptionsScreen()),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Icon(
              Icons.notifications_none_rounded,
              size: 24,
              color: Colors.white,
            ),
            if (Hive.isBoxOpen(AnnouncementStore.boxName) &&
                AnnouncementStore().unseenCount() > 0)
              Positioned(
                top: 1,
                right: 2,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.accent,
                    border: Border.all(color: AppColors.bg, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    // Rebuild the dot when the announcements box changes (e.g. markAllSeen).
    if (!Hive.isBoxOpen(AnnouncementStore.boxName)) return bell();
    return ValueListenableBuilder(
      valueListenable: Hive.box(AnnouncementStore.boxName).listenable(),
      builder: (context, _, child) => bell(),
    );
  }

  /// Builds one provider-defined browse row (poster cards). The section is
  /// already guaranteed non-empty by [SourceRepository.home].
  Widget _sectionRow(HomeSection section) {
    final items = section.items;
    return _animated(
      ContentRow(
        title: section.title,
        itemWidth: 140,
        itemHeight: 236,
        itemCount: items.length,
        onSeeAll: () => _openSeeAll(section),
        itemBuilder: (c, i) => PosterCard(
          title: items[i].title,
          imageUrl: items[i].cover,
          headers: items[i].coverHeaders,
          cellWidth: 140,
          onTap: () => _openDetail(items[i]),
          onLongPress: () => _showInfo(items[i]),
        ),
      ),
    );
  }

  /// Open the full history screen ("See all"). Lands on the tab matching the
  /// current content mode — the [ContentMode] enum is ordered anime/manga/novel,
  /// the same order as the History tabs — so reading modes open on Manga/Novel.
  void _openHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            HistoryScreen(initialIndex: sl<ContentModeCubit>().state.index),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Open the full-grid "See All" view of a browse row.
  void _openSeeAll(HomeSection section) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SeeAllScreen(
          title: section.title,
          items: section.items,
          onTap: _openDetail,
          onLongPress: _showInfo,
          // Only paginable rows (Aniyomi popular/latest, CloudStream mainPage)
          // carry a `more` descriptor; everything else stays a fixed list.
          onLoadMore: section.more == null
              ? null
              : (page) => _repo.browseMore(section.more!, page),
        ),
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  /// Shown at the top of Home when the session lapsed — cloud sync is silently
  /// off until the user reconnects. Tapping re-authenticates in place (no logout
  /// / no wipe) and then refreshes Home to surface the freshly-synced rows.
  Widget _reconnectBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () async {
            final ok = await showReconnectDialog(context) ?? false;
            if (ok && mounted) context.read<HomeCubit>().load();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.sync_problem_rounded,
                  color: AppColors.accent,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Reconnect to sync', style: AppText.body),
                      Text(
                        'Your session expired — tap to sign in and sync your library.',
                        style: AppText.caption,
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A row of two cards under the banner, showing the two modes
  /// you're NOT in. Reactive to [ContentModeCubit] so they re-label the instant
  /// a switch lands. Tapping runs the sword-slash into that mode.
  Widget _modeCards() {
    return BlocBuilder<ContentModeCubit, ContentMode>(
      bloc: sl<ContentModeCubit>(),
      builder: (context, current) {
        final others = ContentMode.values.where((m) => m != current).toList();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            children: [
              for (var i = 0; i < others.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: _modeCard(others[i])),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _modeCard(ContentMode m) {
    final cover = _modeArt(m);
    return GestureDetector(
      onTap: _slashing ? null : () => _enterMode(m),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 52,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background: a cover from the user's recent content for this
              // mode, else a themed gradient when they've nothing there yet.
              _modeArtBg(cover),
              // Scrim so the white icon + label stay legible over any art.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xCC000000), Color(0x55000000)],
                  ),
                ),
              ),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(m.icon, size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      m.label,
                      style: AppText.body.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        shadows: const [
                          Shadow(color: Colors.black, blurRadius: 6),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A representative cover for [m] from the user's own history — last watched
  /// show (streaming) or last read manga/novel. Null when there's nothing yet.
  ({String? cover, Map<String, String>? headers}) _modeArt(ContentMode m) {
    if (m == ContentMode.anime) {
      if (!Hive.isBoxOpen(WatchHistory.boxName)) return (cover: null, headers: null);
      for (final e in sl<WatchHistory>().all()) {
        final c = e.thumbnail ?? e.cover;
        if (c != null && c.isNotEmpty) return (cover: c, headers: e.coverHeaders);
      }
      return (cover: null, headers: null);
    }
    if (!Hive.isBoxOpen(ReadHistory.boxName)) return (cover: null, headers: null);
    final type = m == ContentMode.manga ? ProviderType.manga : ProviderType.novel;
    for (final e in sl<ReadHistory>().all()) {
      if (e.type == type && (e.cover?.isNotEmpty ?? false)) {
        return (cover: e.cover, headers: e.coverHeaders);
      }
    }
    return (cover: null, headers: null);
  }

  Widget _modeArtBg(({String? cover, Map<String, String>? headers}) art) {
    final url = art.cover;
    if (url == null || url.isEmpty) {
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.surface2, AppColors.surface],
          ),
        ),
      );
    }
    if (art.headers?['x-ani-src'] != null ||
        art.headers?['x-mihon-src'] != null) {
      return Image(
        image: ResizeImage(
          art.headers?['x-ani-src'] != null
              ? AniyomiImage(int.parse(art.headers!['x-ani-src']!), url)
              : MihonImage(int.parse(art.headers!['x-mihon-src']!), url),
          width: 420,
        ),
        fit: BoxFit.cover,
        alignment: const Alignment(0, -0.2),
        errorBuilder: (_, _, _) => ColoredBox(color: AppColors.surface2),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: art.headers,
      memCacheWidth: 420,
      fit: BoxFit.cover,
      alignment: const Alignment(0, -0.2),
      placeholder: (_, _) => ColoredBox(color: AppColors.surface2),
      errorWidget: (_, _, _) => ColoredBox(color: AppColors.surface2),
    );
  }

  /// Kicks off the slash transition into [m]. The actual mode swap happens
  /// mid-animation via the controller listener wired in [initState].
  void _enterMode(ContentMode m) {
    if (_slashing) return;
    setState(() {
      _slashing = true;
      _slashSwapped = false;
      _slashTarget = m;
    });
    _slashCtrl.forward(from: 0);
  }

  /// Full-screen logo-strike overlay: the mark springs in at centre behind a
  /// scrim (peaking at the midpoint to hide the content swap), a red glow pulses
  /// and a steel glint sweeps the blade at the strike. Absorbs taps for its
  /// ~600ms so the switch can't be double-fired.
  Widget _slashOverlay() {
    const logoSize = 152.0;
    return Positioned.fill(
      child: AbsorbPointer(
        child: AnimatedBuilder(
          animation: _slashCtrl,
          builder: (context, _) {
            final t = _slashCtrl.value;
            // Triangular pulse: 0 at the ends, 1 at the midpoint.
            final scrim = (1 - (t * 2 - 1).abs()).clamp(0.0, 1.0);
            // Spring in (easeOutBack overshoots ~1), then a slight scale-up on
            // the way out as it fades.
            final inP = (t / 0.45).clamp(0.0, 1.0);
            final outP = ((t - 0.75) / 0.25).clamp(0.0, 1.0);
            final scale =
                0.62 + 0.38 * Curves.easeOutBack.transform(inP) + outP * 0.12;
            final logoOpacity =
                (t < 0.12
                        ? t / 0.12
                        : t > 0.8
                        ? (1 - t) / 0.2
                        : 1.0)
                    .clamp(0.0, 1.0);
            // Steel glint: a white streak that sweeps across the mark around the
            // strike (t≈0.38–0.62, peaking with the swap).
            final glintOn = t > 0.38 && t < 0.62;
            final glintP = ((t - 0.38) / 0.24).clamp(0.0, 1.0);
            final glintPulse = (1 - (glintP * 2 - 1).abs()).clamp(0.0, 1.0);

            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: AppColors.bg.withValues(alpha: scrim * 0.92),
                  ),
                ),
                Center(
                  child: Opacity(
                    opacity: logoOpacity,
                    child: Transform.scale(
                      scale: scale,
                      child: SizedBox(
                        width: logoSize,
                        height: logoSize,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Red energy glow behind the mark.
                            SizedBox(
                              width: logoSize * 0.8,
                              height: logoSize * 0.8,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.accent.withValues(
                                        alpha: 0.5 * scrim,
                                      ),
                                      blurRadius: 48,
                                      spreadRadius: 4,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Image.asset(
                              'assets/icon/logo_mark.png',
                              width: logoSize,
                              height: logoSize,
                            ),
                            if (glintOn)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(26),
                                child: SizedBox(
                                  width: logoSize,
                                  height: logoSize,
                                  child: Transform.translate(
                                    offset: Offset(
                                      (glintP * 2 - 1) * logoSize * 0.9,
                                      0,
                                    ),
                                    child: Transform.rotate(
                                      angle: -0.5,
                                      child: Container(
                                        width: 34,
                                        height: logoSize * 2,
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [
                                              Colors.white.withValues(alpha: 0),
                                              Colors.white.withValues(
                                                alpha: 0.85 * glintPulse,
                                              ),
                                              Colors.white.withValues(alpha: 0),
                                            ],
                                          ),
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
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const HomeScreenTv();
    // Continue Watching is a logged-in feature; hide the row when signed out.
    final authState = context.watch<AuthCubit>().state;
    final loggedIn = authState.isLoggedIn;
    // Session lapsed (logged-in from cache only) → cloud sync is silently off.
    final needsReconnect = loggedIn && authState.needsReconnect;

    return BlocListener<ActiveSourceCubit, String>(
      listenWhen: (prev, curr) => prev != curr,
      listener: (context, _) {
        if (!mounted) return;
        _metaCache.clear();
        _heroPrewarmed = false;
        // reset:true clears the old source's rows so the switch is visible
        // immediately (skeletons), even if the new source's home is slow.
        context.read<HomeCubit>().load(reset: true);
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        // Extend content behind the status bar; the floating header handles
        // its own SafeArea(bottom: false).
        body: Stack(
          children: [
            RefreshIndicator(
              color: AppColors.accent,
              onRefresh: () => context.read<HomeCubit>().load(),
              child: BlocBuilder<HomeCubit, HomeState>(
                builder: (context, state) {
                  final sections = state.sections ?? const <HomeSection>[];
                  // The first section feeds the hero carousel; the rest render as
                  // browse rows (so the spotlight isn't duplicated right below it).
                  // A source with only ONE section (e.g. SubsPlease's single "Latest"
                  // feed) would otherwise show a hero and NO rows — keep that one
                  // section as a row too so there's something to browse.
                  //
                  // Aniyomi AND Mihon sources expose exactly two sections
                  // (Popular + Latest); dropping the first would hide Popular
                  // entirely, so keep the full list as rows for them — the banner
                  // still spotlights Popular, and the row repeats it (like the
                  // Aniyomi/Mihon apps' Popular grid).
                  final firstId = sections.isNotEmpty
                      ? (sections.first.more?.sourceId ?? '')
                      : '';
                  final firstIsNativeCatalog =
                      firstId.startsWith('ani:') || firstId.startsWith('mihon:');
                  final rowSections =
                      (sections.length > 1 && !firstIsNativeCatalog)
                      ? sections.sublist(1)
                      : sections;
                  final showSkeletons = state.loading && sections.isEmpty;
                  // The load finished but the source returned no rows — almost
                  // always a dead/blocked site (or a search-only source). Show a
                  // clear message instead of a blank screen.
                  final loadedEmpty =
                      !state.loading &&
                      state.sections != null &&
                      state.sections!.isEmpty;
                  // Manga/novel with nothing installed: the mode-switch fallback
                  // sets a matching source when one exists, so a reading mode
                  // still on a non-matching (usually stale anime) active id means
                  // nothing's installed for it — show the install guide and drop
                  // the leaking anime rows/hero. Cheap DI-free prefix check, so
                  // it's safe to run every build (unlike categorizedSources()).
                  // Anime's own zero-source case (skipped setup) has no source to
                  // load and flows through `loadedEmpty` → HomeLoadedEmptyView.
                  final activeId = context.read<ActiveSourceCubit>().state;
                  final noSourceForMode = switch (sl<ContentModeCubit>().state) {
                    ContentMode.manga => !activeId.startsWith('mihon:'),
                    ContentMode.novel => !activeId.startsWith('lnr:'),
                    ContentMode.anime => false,
                  };
                  return CustomScrollView(
                    slivers: [
                      // ── Hero + floating header (first sliver) ─────────────────
                      SliverToBoxAdapter(
                        child: Builder(
                          builder: (context) {
                            final heroItems = state.heroItems;
                            final hasHero = heroItems.isNotEmpty;
                            if (hasHero) _prewarmHeroMeta(heroItems);

                            if (hasHero && !noSourceForMode) {
                              return Stack(
                                children: [
                                  // Auto-rotating carousel (up to 6 trending items)
                                  FeaturedCarousel(
                                    items: heroItems,
                                    reading:
                                        sl<ContentModeCubit>().state.isReading,
                                    inList: (m) => _myList.contains(m),
                                    onPlay: _playFeatured,
                                    onInfo: _openDetail,
                                    onToggleList: (m) => showListStatusSheet(
                                      context,
                                      item: m,
                                      onChanged: () {
                                        if (mounted) setState(() {});
                                      },
                                    ),
                                    meta: _heroMeta,
                                    style: HeroTransition.cinematic,
                                  ),
                                  // Floating header sits on top
                                  Positioned(
                                    top: 0,
                                    left: 0,
                                    right: 0,
                                    child: _buildHeader(),
                                  ),
                                ],
                              );
                            }

                            // While loading or on error: plain header on bg colour.
                            return ColoredBox(
                              color: AppColors.bg,
                              child: _buildHeader(),
                            );
                          },
                        ),
                      ),

                      // ── Mode cards (switch Anime / Manga / Novel) ─────────────
                      SliverToBoxAdapter(child: _modeCards()),

                      // ── Reconnect banner (session lapsed → sync is off) ───────
                      if (needsReconnect)
                        SliverToBoxAdapter(child: _reconnectBanner()),

                      // ── Continue Watching / Continue Reading ──────────────────
                      // Driven by the watch/read history box's listenable, NOT a
                      // one-shot read: the cloud pull writes history AFTER this
                      // build runs (the login / boot-migration race), so reading
                      // recent() once here would render blank until the next
                      // navigation. Reacting to the box makes the row appear the
                      // instant the pull lands. Swapped by ContentMode — see
                      // ContinueSection.
                      ContinueSection(
                        loggedIn: loggedIn,
                        onResume: _resume,
                        onLongPress: _showContinueInfo,
                        onSeeAll: _openHistory,
                        onResumeReading: _resumeReading,
                        onLongPressReading: _showContinueReadingInfo,
                      ),

                      // ── Provider-defined browse rows (CloudStream-style) ──────
                      // The active provider decides the rows + their names; empty
                      // ones are already dropped by SourceRepository.home.
                      if (showSkeletons && !noSourceForMode)
                        ...List.generate(
                          3,
                          (_) => const SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 10),
                              child: RowSkeleton(),
                            ),
                          ),
                        )
                      else if (noSourceForMode || loadedEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: HomeLoadedEmptyView(
                            mode: sl<ContentModeCubit>().state,
                            sourceName: sl<SourceRepository>().displayName(
                              context.read<ActiveSourceCubit>().state,
                            ),
                            onRetry: () =>
                                context.read<HomeCubit>().load(reset: true),
                            // No-source guide points at the Providers hub (all
                            // ecosystems); the source-returned-nothing case
                            // (_SourceUnavailable) keeps its retry.
                            onInstallSources: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ProvidersHubScreen(),
                              ),
                            ),
                            // Cloudflare-blocked (Mihon) source: offer the visible
                            // solve, then reload once the user closes the WebView.
                            cloudflareUrl: state.cloudflareUrl,
                            onSolveCloudflare: state.cloudflareUrl == null
                                ? null
                                : () async {
                                    await MihonExtensionService.solveCloudflare(
                                      state.cloudflareUrl!,
                                    );
                                    if (context.mounted) {
                                      context
                                          .read<HomeCubit>()
                                          .load(reset: true);
                                    }
                                  },
                          ),
                        )
                      else
                        ...rowSections.map(
                          (s) => SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: _sectionRow(s),
                            ),
                          ),
                        ),

                      // ── Bottom padding ────────────────────────────────────────
                      // Clear the floating dock: its height arrives as MediaQuery
                      // bottom padding (the shell's extendBody). A fixed gap hid the
                      // last row's titles behind the capsule.
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 24 + MediaQuery.paddingOf(context).bottom,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (_slashing) _slashOverlay(),
          ],
        ),
      ),
    );
  }
}

/// Home's "provider returned no sections" branch. A reading mode with
/// literally nothing installed for it gets a message that says so, with an
/// action into the install flow — today's [_SourceUnavailable] ("couldn't
/// load, try again") is flat wrong there, since nothing failed, there's just
/// nothing set up. Anime mode (and a reading mode whose installed source
/// failed to load) keeps [_SourceUnavailable] exactly as before.
///
/// Extracted as its own widget — rather than inlined in [_HomeViewState]'s
/// build — so this decision is testable without pumping the real
/// [HomeScreen], whose `initState` fires a real network call.
class HomeLoadedEmptyView extends StatelessWidget {
  const HomeLoadedEmptyView({
    super.key,
    required this.mode,
    required this.sourceName,
    required this.onRetry,
    required this.onInstallSources,
    this.cloudflareUrl,
    this.onSolveCloudflare,
  });

  final ContentMode mode;
  final String sourceName;
  final VoidCallback onRetry;
  final VoidCallback onInstallSources;

  /// Non-null when the active source is blocked by a Cloudflare challenge;
  /// [onSolveCloudflare] opens the visible solve WebView and reloads after.
  final String? cloudflareUrl;
  final Future<void> Function()? onSolveCloudflare;

  @override
  Widget build(BuildContext context) {
    // A Cloudflare block takes priority over the no-sources guide: the source
    // IS installed, it's just gated behind a challenge the user can solve.
    if (cloudflareUrl != null && onSolveCloudflare != null) {
      return _SourceUnavailable(
        sourceName: sourceName,
        onRetry: onRetry,
        onSolveCloudflare: onSolveCloudflare,
      );
    }
    if (!hasSourcesFor(mode)) {
      return _NoSourcesGuide(mode: mode, onBrowse: onInstallSources);
    }
    return _SourceUnavailable(sourceName: sourceName, onRetry: onRetry);
  }
}

/// Friendly "nothing installed for this mode yet" state — a mode-aware icon in
/// a soft accent circle, a warm one-liner, and a single rounded button into
/// Providers. Replaces the bare [EmptyState] so an empty manga/novel/streaming
/// home reads as "let's set this up" rather than an error.
class _NoSourcesGuide extends StatelessWidget {
  const _NoSourcesGuide({required this.mode, required this.onBrowse});

  final ContentMode mode;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    final label = mode.label; // Streaming / Manga / Novel
    final (icon, noun) = switch (mode) {
      ContentMode.anime => (Icons.live_tv_rounded, 'shows'),
      ContentMode.manga => (Icons.auto_stories_rounded, 'manga'),
      ContentMode.novel => (Icons.menu_book_rounded, 'novels'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(40, 24, 40, 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 46, color: AppColors.accent),
            ),
            const SizedBox(height: 22),
            Text(
              'No $label sources yet',
              textAlign: TextAlign.center,
              style: AppText.headline.copyWith(fontSize: 20),
            ),
            const SizedBox(height: 10),
            Text(
              'Add a source from Providers and your $noun will show up here.',
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: onBrowse,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('Browse sources'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                textStyle: AppText.button.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown on Home when the active source finished loading but returned no rows —
/// typically a dead/blocked site. Offers a retry and points to the source
/// switcher. Continue Watching (app-side) still renders above this.
class _SourceUnavailable extends StatelessWidget {
  const _SourceUnavailable({
    required this.sourceName,
    required this.onRetry,
    this.onSolveCloudflare,
  });

  final String sourceName;
  final VoidCallback onRetry;

  /// When set, this is a Cloudflare block (not a generic outage): show a shield
  /// + a primary "Solve Cloudflare" action that opens the visible solve WebView.
  final Future<void> Function()? onSolveCloudflare;

  static const Color _cloudflareOrange = Color(0xFFF48120);

  @override
  Widget build(BuildContext context) {
    final isCloudflare = onSolveCloudflare != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 40, 36, 56),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: isCloudflare
                  ? _cloudflareOrange.withValues(alpha: 0.14)
                  : AppColors.surface,
              shape: BoxShape.circle,
            ),
            child: Icon(
              isCloudflare ? Icons.shield_rounded : Icons.cloud_off_rounded,
              size: 40,
              color: isCloudflare ? _cloudflareOrange : AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            isCloudflare
                ? '$sourceName is protected by Cloudflare'
                : "Couldn't load $sourceName",
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            isCloudflare
                ? 'Complete the Cloudflare check once and this source will '
                      'load normally from then on.'
                : "This source isn't responding right now. It may be down or "
                      "blocking requests — try again, or switch to another "
                      "source from the top.",
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 24),
          if (isCloudflare) ...[
            ElevatedButton.icon(
              onPressed: () => onSolveCloudflare!(),
              icon: const Icon(Icons.shield_rounded, size: 20),
              label: const Text('Solve Cloudflare'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _cloudflareOrange,
                foregroundColor: Colors.white,
                elevation: 0,
                padding:
                    const EdgeInsets.symmetric(horizontal: 30, vertical: 13),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
              ),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
              ),
            ),
          ] else
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 20),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                padding:
                    const EdgeInsets.symmetric(horizontal: 30, vertical: 13),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(26),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The reader `_resumeReading` pushes for a resumed
/// [ReadEntry]: [MangaReaderScreen] for [ProviderType.manga], otherwise
/// [NovelReaderScreen] (novel, and [ReadEntry.type]'s legacy-row default).
/// Pulled out as a plain top-level function so the routing decision is
/// testable without pumping the whole [HomeScreen] (whose initState makes a
/// real update-check network call and opens community/announcement Hive
/// boxes).
Widget readerFor(ReadEntry e, Episode chapter) {
  if (e.type == ProviderType.manga) {
    return MangaReaderScreen(
      sourceId: e.sourceId,
      showId: e.showId,
      showTitle: e.title,
      cover: e.cover,
      chapters: [chapter],
      startIndex: 0,
      resolveChapters: true,
    );
  }
  return NovelReaderScreen(
    sourceId: e.sourceId,
    showId: e.showId,
    showTitle: e.title,
    cover: e.cover,
    chapters: [chapter],
    startIndex: 0,
    resolveChapters: true,
  );
}
