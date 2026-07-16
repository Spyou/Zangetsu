import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../announce/announcement.dart';
import '../announce/announcement_service.dart';
import '../playback/list_status_store.dart';
import '../playback/my_list.dart';
import '../playback/playback_prefs.dart';
import '../playback/search_history.dart';
import '../playback/search_prefs.dart';
import '../playback/search_source_prefs.dart';
import '../playback/source_health_store.dart';
import '../schedule/airing_service.dart';
import '../schedule/coming_soon_service.dart';
import '../search/title_suggestion_service.dart';
import '../playback/skip_service.dart';
import '../playback/resume_store.dart';
import '../playback/title_prefs.dart';
import '../playback/watch_history.dart';
import '../provider/cf_clearance_store.dart';
import '../provider/cloudstream_provider.dart';
import '../provider/provider_downloader.dart';
import '../provider/provider_manager.dart';
import '../share/open_link_service.dart';
import '../provider/provider_registry.dart';
import '../provider/provider_repo_registry.dart';
import '../repository/provider_settings_repository.dart';
import '../repository/source_repository.dart';
import '../state/active_source_cubit.dart';
import '../metadata/metadata_enrichment.dart';
import '../metadata/people_service.dart';
import '../metadata/tmdb.dart';
import '../metadata/title_logo_service.dart';
import '../trailer/trailer_service.dart';
import '../anilist/anilist_service.dart';
import '../anilist/anilist_store.dart';
import '../tracker/mal_service.dart';
import '../tracker/simkl_service.dart';
import '../tracker/tracker_hub.dart';
import '../app_mode.dart';
import '../appwrite/appwrite_service.dart';
import '../backup/backup_service.dart';
import '../backup/sources_backup.dart';
import '../backup/library_backup.dart';
import '../backup/settings_backup.dart';
import '../download/download_manager.dart';
import '../download/download_prefs.dart';
import '../download/download_service.dart';
import '../torrent/torrent_download_service.dart';
import '../torrent/torrent_prefs.dart';
import '../torrent/torrent_service.dart';
import '../notify/subscription_store.dart';
import '../notify/subscription_checker.dart';
import '../discord/discord_rpc.dart';
import '../aniyomi/aniyomi_extension_service.dart';
import '../aniyomi/aniyomi_provider.dart';
import '../../features/auth/auth_cubit.dart';
import '../../features/home/cubit/home_cubit.dart';
import '../../features/watch_together/watch_room_service.dart';
import '../../features/watch_together/watch_together_controller.dart';
import '../cast/cast_controller.dart';
import '../cast/cast_proxy.dart';

final GetIt sl = GetIt.instance;

/// One-time app bootstrap: Hive boxes, Dio, the shared provider runtime,
/// the provider registry (built-in providers seeded from assets + any
/// repo-installed providers), and the bundled extractors.
const _deviceChannel = MethodChannel('com.spyou.watch_app/device');

Future<void> initDependencies() async {
  // Detect device class first so every subsequent registration can gate on it.
  // Wrapped in try/catch: no native handler (tests, iOS, web) → phone behavior.
  bool isTv = false;
  try {
    isTv = (await _deviceChannel.invokeMethod<bool>('isTv')) ?? false;
  } catch (_) {
    isTv = false;
  }
  sl.registerSingleton<AppMode>(AppMode(isTv: isTv));

  await Hive.initFlutter();
  // Cache of the signed-in user so the logged-in UI appears INSTANTLY on boot
  // (AuthCubit reads it before the network session check). See AuthCubit.restore.
  await Hive.openBox(AuthCubit.cacheBoxName);
  await ProviderDownloader.init();

  // Appwrite first (no network on construct) so the library stores can use it
  // for cloud sync. Public project id/endpoint only — no server key.
  sl.registerSingleton<AppwriteService>(AppwriteService());
  // Resolved lazily at call time (AuthCubit registers further down); null when
  // signed out so the stores stay local-only.
  String? currentUserId() =>
      sl.isRegistered<AuthCubit>() ? sl<AuthCubit>().state.user?.$id : null;

  await ResumeStore.init();
  sl.registerSingleton<ResumeStore>(ResumeStore());
  await WatchHistory.init();
  sl.registerSingleton<WatchHistory>(
    WatchHistory(sl<AppwriteService>(), currentUserId),
  );
  sl.registerSingleton<WatchRoomService>(WatchRoomService(sl<AppwriteService>()));
  sl.registerSingleton<WatchTogetherController>(
    WatchTogetherController(sl<WatchRoomService>()),
  );
  await MyListStore.init();
  sl.registerSingleton<MyListStore>(
    MyListStore(sl<AppwriteService>(), currentUserId),
  );
  await ListStatusStore.init();
  sl.registerSingleton<ListStatusStore>(ListStatusStore());
  await TitlePrefsStore.init();
  sl.registerSingleton<TitlePrefsStore>(TitlePrefsStore());
  await PlaybackPrefs.init();
  sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
  await DownloadPrefs.init();
  sl.registerSingleton<DownloadPrefs>(DownloadPrefs());
  await TorrentPrefs.init();
  sl.registerSingleton<TorrentPrefs>(TorrentPrefs());
  sl.registerSingleton<TorrentService>(TorrentService());
  sl.registerSingleton<TorrentDownloadService>(TorrentDownloadService());
  await SearchHistory.init();
  sl.registerSingleton<SearchHistory>(SearchHistory());
  await SearchSourcePrefs.init();
  sl.registerSingleton<SearchSourcePrefs>(SearchSourcePrefs());
  await SearchPrefs.init();
  sl.registerSingleton<SearchPrefs>(SearchPrefs());
  // Per-source reliability: orders search healthy-first, recoverably skips dead
  // sources, and backs the "Source health" test screen.
  await SourceHealthStore.init();
  sl.registerSingleton<SourceHealthStore>(SourceHealthStore());
  // Persisted Cloudflare clearances: JS sources reuse a solved cf_clearance
  // across restarts instead of re-popping the "Verifying…" solver each session.
  await CfClearanceStore.init();

  final dio = Dio(
    BaseOptions(
      // 8s bounds every provider/extractor fetch (incl. embed hosts that hang,
      // e.g. streamlare's anti-bot endpoint) so source resolution can't stall ~20s.
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      headers: {'User-Agent': 'Mozilla/5.0 (WATCH_APP) Chrome/120.0'},
    ),
  );
  // TMDB v3 auth: attach our api_key to every TMDB request (the old keyless
  // proxy died with a 1027). Per-IP limits, so one key scales to all users.
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.uri.host == Tmdb.host) {
          options.queryParameters = {
            ...options.queryParameters,
            'api_key': Tmdb.apiKey,
          };
        }
        handler.next(options);
      },
    ),
  );
  sl.registerSingleton<Dio>(dio);
  sl.registerSingleton<AiringService>(AiringService(sl<Dio>()));
  sl.registerSingleton<ComingSoonService>(ComingSoonService(sl<Dio>()));

  // Lightweight title autocomplete for the search field (one fast AniList call
  // per debounced keystroke — NOT the heavy multi-source provider search).
  sl.registerSingleton<TitleSuggestionService>(TitleSuggestionService(dio));

  // Discord Rich Presence (opt-in; off until the user connects + enables it).
  await DiscordRpc.init();
  sl.registerSingleton<DiscordRpc>(DiscordRpc(dio));
  // Restore the saved token + reconnect now (before the UI), so presence resumes
  // promptly after a restart instead of looking disconnected.
  await sl<DiscordRpc>().start();

  // Metadata-API trailer lookups (AniList for anime, TMDB for movie/TV).
  sl.registerSingleton<TrailerService>(TrailerService(dio));

  // Detail-screen Cast + Relations enrichment (AniList for anime, TMDB for
  // movie/TV). Keys off the malId/tmdbId the providers already expose.
  sl.registerSingleton<MetadataEnrichment>(MetadataEnrichment(dio));

  // Person pages (characters + voice actors/staff from AniList, movie/TV people
  // from TMDB), opened from the Detail screen's Cast tab.
  sl.registerSingleton<PeopleService>(PeopleService(dio));

  // TMDB title-logo lookup for the home hero (stylized title art; falls back to
  // text when absent). Cached per title (in-memory + a persisted Hive box, so
  // the logo doesn't re-resolve / pop-in on later launches).
  await TitleLogoService.init();
  sl.registerSingleton<TitleLogoService>(TitleLogoService(dio));

  // Accurate OP/ED skip times for anime (AniList → MAL id → AniSkip).
  sl.registerSingleton<SkipService>(SkipService(dio));

  // AniList account sync (auto-scrobble watched episodes + list import). The
  // box holds the OAuth token; the service listens for the OAuth redirect.
  await AniListStore.init();
  sl.registerSingleton<AniListService>(AniListService(dio));
  // Retry any scrobbles that queued while offline/disconnected last session.
  sl<AniListService>().flushPending();

  // Additional trackers (MyAnimeList, Simkl) + the fan-out hub. Each writes to
  // its own service; the hub pushes every list/progress change to all connected.
  await MalService.init();
  sl.registerSingleton<MalService>(MalService(dio));
  await SimklService.init();
  sl.registerSingleton<SimklService>(SimklService(dio));
  sl.registerSingleton<TrackerHub>(
    TrackerHub([sl<AniListService>(), sl<MalService>(), sl<SimklService>()]),
  );

  // Share deep links (zangetsu://open?…): opens a shared title's Detail, or
  // reports an uninstalled source. Eager so its AppLinks listener is live from
  // boot; navigation is deferred until the root Navigator exists.
  sl.registerSingleton<OpenLinkService>(OpenLinkService());

  // AuthCubit is global so any widget can gate on login. AppwriteService is
  // already registered above (the library stores depend on it).
  sl.registerSingleton<AuthCubit>(AuthCubit(sl<AppwriteService>()));

  final manager = ProviderManager(dio: dio);
  sl.registerSingleton<ProviderManager>(manager);
  final downloader = ProviderDownloader(dio: dio);
  sl.registerSingleton<ProviderDownloader>(downloader);

  // CloudStream sources route through a native MethodChannel (Android-only).
  // The repo box (persisted owner/repo grouping) MUST be opened before the
  // manager touches it. Loading the installed .cs3 plugins (DexClassLoad +
  // instantiate) is deferred to a microtask AFTER boot (see the guarded step
  // near the end of this function) so the splash is instant regardless of how
  // many extensions are installed — and a slow/misbehaving plugin can't stall
  // startup. Sources register a moment after launch; a saved `cs:` active
  // source is restored via reapplySaved + a Home reload.
  await CloudStreamManager.init();
  final csManager = CloudStreamManager();
  sl.registerSingleton<CloudStreamManager>(csManager);

  // Aniyomi extension registry — empty on first launch; populated by the
  // guarded boot step below once the box and the channel are ready.
  final aniyomiManager = AniyomiManager();
  sl.registerSingleton<AniyomiManager>(aniyomiManager);

  // --- Provider registry data layer ---------------------------------
  await ProviderReposRegistry.init();
  await ProviderRegistry.init();
  await ProviderSettingsRepository.init();

  final repos = ProviderReposRegistry(dio: dio);
  final settings = ProviderSettingsRepository();
  final registry = ProviderRegistry(
    downloader: downloader,
    manager: manager,
    repos: repos,
  );
  sl.registerSingleton<ProviderReposRegistry>(repos);
  sl.registerSingleton<ProviderSettingsRepository>(settings);
  sl.registerSingleton<ProviderRegistry>(registry);
  sl.registerSingleton<BackupService>(BackupService(
    SourcesBackup(sl<ProviderReposRegistry>(), sl<ProviderRegistry>(),
        sl.isRegistered<CloudStreamManager>() ? sl<CloudStreamManager>() : null,
        aniyomi: AniyomiExtensionService()),
    LibraryBackup(),
    SettingsBackup(),
  ));

  // Load bundled extractor BEFORE the providers so getVideoSources can resolve.
  // Extractors are NOT providers — they stay loaded directly on the manager.
  final extractorJs = await rootBundle.loadString(
    'extractors/example_embed.js',
  );
  manager.loadExtractor(extractorId: 'example_embed', jsSource: extractorJs);

  // Real embed-host extractors. Order doesn't matter; each registers its
  // own hosts in __extractors and is reached via extractVideo().
  for (final ex in ['okru', 'mp4upload', 'streamlare', 'doodstream']) {
    final js = await rootBundle.loadString('extractors/$ex.js');
    manager.loadExtractor(extractorId: ex, jsSource: js);
  }

  // The app ships with NO built-in providers — every source comes from a repo
  // (the Zangetsu repo is installed on first launch via onboarding). Drop any
  // legacy `bundled://` entries left by older installs, then load the
  // repo-installed providers persisted from previous launches.
  await registry.purgeBundled();
  // Load repo-installed JS providers into the runtime. Bounded so a provider
  // whose JS HANGS (flutter_js can deadlock) can't trap the splash — the
  // reported "stuck on the splash for minutes":
  //   • per-entry cap → one bad source is skipped, never fatal to the rest;
  //   • total cap → if the whole step is still running (e.g. a runtime
  //     deadlock), boot NOW and let the rest finish in the BACKGROUND, then
  //     restore the saved active source + refresh Home so their content shows
  //     without a relaunch.
  // Normal boots load in ~1-2s, well under both caps, so this is a no-op there.
  final providerLoad =
      registry.loadAll(perEntryTimeout: const Duration(seconds: 6));
  await providerLoad.timeout(const Duration(seconds: 8), onTimeout: () {
    debugPrint('[boot] provider load exceeded 8s — booting now; '
        'remaining providers finish in the background');
    providerLoad.whenComplete(() {
      if (sl.isRegistered<ActiveSourceCubit>()) {
        sl<ActiveSourceCubit>()
            .reapplySaved((id) => manager.installedIds.contains(id));
      }
      if (sl.isRegistered<HomeCubit>()) sl<HomeCubit>().load();
    });
    return const <String>[];
  });

  // Push every saved per-provider settings row into the runtime so the
  // first provider call sees the user's choices. Strip the repoUrl prefix
  // off the composite key → sourceId.
  for (final entry in settings.getAll().entries) {
    final sourceId = ProviderRegistry.sourceIdOf(entry.key);
    manager.setSettings(sourceId, entry.value);
  }

  // Guarded Aniyomi boot step — reload any previously installed extensions.
  // This runs on a microtask so it never blocks or slows app startup. Any
  // failure is caught and logged; it must never propagate to the caller.
  Future.microtask(() async {
    try {
      if (!Hive.isBoxOpen(AniyomiExtensionService.installedBoxName)) {
        await Hive.openBox<dynamic>(AniyomiExtensionService.installedBoxName);
      }
      // Repo-URL box too, so Backup's sync build() can read it any time.
      if (!Hive.isBoxOpen('aniyomi_repos')) {
        await Hive.openBox<String>('aniyomi_repos');
      }
      final box = Hive.box<dynamic>(AniyomiExtensionService.installedBoxName);
      if (box.isEmpty) {
        return; // nothing installed yet
      }
      final support = await getApplicationSupportDirectory();
      final aniyomiDir = Directory('${support.path}/aniyomi');
      final service = AniyomiExtensionService();
      await service.loadInstalled(aniyomiDir.path);
      final sources = await service.listSources();
      final providers = sources.map((s) => AniyomiProvider(info: s)).toList();
      aniyomiManager.registerAll(providers);
      // Honor the user's saved active source when it's an Aniyomi source that
      // wasn't loaded yet at boot (ActiveSourceCubit fell back to a JS source).
      // A saved NSFW Aniyomi source is treated as absent when the pref is off
      // so it falls back gracefully rather than staying as the active source.
      if (sl.isRegistered<ActiveSourceCubit>()) {
        final showNsfw = sl.isRegistered<PlaybackPrefs>()
            ? sl<PlaybackPrefs>().showNsfwAniyomi
            : false;
        final changed = sl<ActiveSourceCubit>().reapplySaved((id) {
          final p = aniyomiManager.get(id);
          if (p == null) return false;
          if (p is AniyomiProvider && p.info.nsfw && !showNsfw) return false;
          return true;
        });
        if (changed && sl.isRegistered<HomeCubit>()) {
          sl<HomeCubit>().load(); // reload Home for the restored source
        }
      }
    } catch (e, st) {
      debugPrint('[aniyomi] boot step failed (non-fatal): $e\n$st');
    }
  });

  // Global cubit so any widget can read/write the active source id and
  // descendants can react via BlocBuilder/BlocListener. Persists the pick to a
  // Hive box and restores it on launch, validated against the providers that
  // actually loaded (so a removed/disabled source falls back to allanime).
  await ActiveSourceCubit.init();
  sl.registerSingleton<ActiveSourceCubit>(
    ActiveSourceCubit(
      box: Hive.box(ActiveSourceCubit.boxName),
      // Valid ids = JS providers (CloudStream + Aniyomi load off the boot
      // path, so a saved `cs:`/`ani:` active source is restored a moment later
      // via reapplySaved rather than being in this initial set).
      valid: {
        ...manager.installedIds,
        ...csManager.all.map((p) => p.sourceId),
      },
    ),
  );

  sl.registerSingleton<SourceRepository>(
    SourceRepository(
      manager: manager,
      csManager: csManager,
      aniManager: aniyomiManager,
      activeSource: sl<ActiveSourceCubit>(),
      prefs: sl<PlaybackPrefs>(),
    ),
  );

  // "New episode" subscriptions (CloudStream-style): the store + the checker
  // that re-fetches each subscribed show's episodes (works for JS and CS via
  // SourceRepository.episodes) and notifies on an increase. Triggered on app
  // launch/resume.
  await SubscriptionStore.init();
  sl.registerSingleton<SubscriptionStore>(SubscriptionStore());
  sl.registerSingleton<SubscriptionChecker>(
    SubscriptionChecker(sl<SourceRepository>(), sl<SubscriptionStore>()),
  );

  // Developer announcements: read a public JSON feed on launch and surface new
  // messages as a bottom sheet + a Notifications-screen history entry.
  await AnnouncementStore.init();
  sl.registerSingleton<AnnouncementStore>(AnnouncementStore());
  sl.registerSingleton<AnnouncementService>(
    AnnouncementService(sl<Dio>(), sl<AnnouncementStore>()),
  );

  // Offline downloads (background_downloader). setup() restores persisted
  // records and starts listening for task progress/status updates.
  await DownloadManager.init();
  await DownloadService.initialize(); // configure the foreground-service host
  sl.registerSingleton<DownloadManager>(
    DownloadManager(sl<SourceRepository>(), sl<DownloadPrefs>())..setup(),
  );

  // Chromecast session controller. Wraps the native zangetsu/cast channel.
  // init() is guarded: if the native side is absent (non-Android, test) the
  // controller stays in CastState.unavailable and never throws.
  sl.registerSingleton<CastController>(CastController());
  try {
    await sl<CastController>().init();
  } catch (_) {
    // Native side missing or init failed — state already defaults to unavailable.
  }

  // On-device HTTP proxy that lets the Chromecast play header-locked streams
  // (it injects the request headers the Cast receiver can't send). Lazily
  // started only when a cast hand-off actually happens.
  sl.registerLazySingleton<CastProxyServer>(() => CastProxyServer());

  // Home data cubit as a singleton so the splash can warm it (preload the
  // rows for the active source) while the intro animation plays — Home then
  // appears already populated instead of flashing skeletons.
  sl.registerLazySingleton<HomeCubit>(() => HomeCubit(sl<SourceRepository>()));

  // Guarded CloudStream boot step — load the installed .cs3 plugins OFF the
  // splash path (see the note where csManager is registered) so startup is
  // instant and a heavy/misbehaving plugin can't stall it. Scheduled here,
  // after ActiveSourceCubit + HomeCubit exist, so the restore below is safe.
  // Any failure is caught and logged; it must never propagate to the caller.
  Future.microtask(() async {
    try {
      await csManager.loadInstalled();
      // Honor a saved `cs:` active source that wasn't loaded yet at boot
      // (ActiveSourceCubit fell back to a JS source). reapplySaved only swaps
      // when the saved id is now valid — it never resets an already-restored
      // source — so this composes cleanly with the Aniyomi step above.
      if (sl.isRegistered<ActiveSourceCubit>()) {
        final changed = sl<ActiveSourceCubit>()
            .reapplySaved((id) => csManager.get(id) != null);
        if (changed && sl.isRegistered<HomeCubit>()) {
          sl<HomeCubit>().load(); // reload Home for the restored source
        }
      }
    } catch (e, st) {
      debugPrint('[cloudstream] deferred load failed (non-fatal): $e\n$st');
    }
  });
}
