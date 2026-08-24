import 'dart:io';
import 'package:watch_app/core/hive/safe_box.dart';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../announce/announcement.dart';
import '../announce/announcement_service.dart';
import '../playback/category_store.dart';
import '../playback/list_status_store.dart';
import '../playback/my_list.dart';
import '../playback/playback_prefs.dart';
import '../playback/pinned_sources.dart';
import '../playback/search_history.dart';
import '../playback/search_prefs.dart';
import '../playback/search_source_prefs.dart';
import '../playback/source_health_store.dart';
import '../schedule/airing_service.dart';
import '../schedule/coming_soon_service.dart';
import '../privacy/incognito_mode.dart';
import '../search/title_suggestion_service.dart';
import '../ui/animation_prefs.dart';
import '../playback/skip_service.dart';
import '../playback/resume_store.dart';
import '../reading/read_history.dart';
import '../reading/read_store.dart';
import '../reading/reader_overrides.dart';
import '../reading/reader_prefs.dart';
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
import '../theme/theme_controller.dart';
import '../metadata/episode_metadata_service.dart';
import '../metadata/metadata_enrichment.dart';
import '../metadata/people_service.dart';
import '../metadata/tmdb.dart';
import '../metadata/title_logo_service.dart';
import '../mode/content_mode_cubit.dart';
import '../trailer/trailer_service.dart';
import '../anilist/anilist_service.dart';
import '../anilist/anilist_store.dart';
import '../tracker/mal_service.dart';
import '../tracker/simkl_service.dart';
import '../tracker/tracker_binding_store.dart';
import '../tracker/tracker_hub.dart';
import '../tracker/relay/tracker_relay.dart';
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
import '../lnreader/lnreader_extension_service.dart';
import '../lnreader/lnreader_manager.dart';
import '../lnreader/novel_lang_prefs.dart';
import '../prefs/source_lang_prefs.dart';
import '../lnreader/lnreader_runtime.dart' show LnReaderHttpResponse;
import '../mihon/mihon_extension_service.dart';
import '../mihon/mihon_manager.dart';
import '../mihon/mihon_provider.dart';
import '../../features/auth/auth_cubit.dart';
import '../../features/auth/migration_bridge.dart';
import '../../features/auth/tv_pairing_service.dart';
import '../../features/home/cubit/home_cubit.dart';
import '../../features/watch_together/watch_room_service.dart';
import '../../features/watch_together/watch_together_controller.dart';
import '../cast/cast_controller.dart';
import '../cast/cast_proxy.dart';
import '../supabase/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show OtpType;

final GetIt sl = GetIt.instance;

/// Browser-like default headers for LNReader plugin requests — a straight
/// mirror of LNReader's own `makeInit` (src/plugins/helpers/fetch.ts). Some
/// novel hosts (e.g. webnovel.com) sit behind Cloudflare bot-fight that 403s
/// a bare request which doesn't look like a browser; it's a fingerprint check,
/// not a challenge to solve, so real LNReader passes these headers and works
/// with no CF solver. Merged UNDER each plugin's own headers so a plugin that
/// sets its own User-Agent (WebNovel ships a desktop-Chrome UA) still wins.
/// Pure headers → identical behaviour on Android and iOS, no WebView.
///
/// Accept-Encoding is intentionally left out: dart:io already sends `gzip` and
/// auto-decompresses it, whereas declaring `deflate` here would hand back a
/// body dart:io won't decode.
const Map<String, String> _lnreaderBrowserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Accept': '*/*',
  'Accept-Language': 'en-US,en;q=0.9',
  'Sec-Fetch-Mode': 'cors',
  'Connection': 'keep-alive',
  'Cache-Control': 'max-age=0',
};

/// Headers alone don't clear webnovel.com's Cloudflare bot-fight — confirmed
/// on-device, still 403 with the full browser header block above. That gate
/// is on the TLS/JA3 fingerprint, and dart:io/Dio's doesn't pass it. Android's
/// native OkHttp (Conscrypt/BoringSSL) has a Chrome-like fingerprint that
/// does — it's how the real LNReader app (RN → OkHttp) gets through — so on
/// Android the LNReader fetch tries this channel (see NovelHttp.kt) before
/// falling back to Dio. iOS/other platforms never touch this and keep using
/// Dio as before.
const MethodChannel _novelHttp = MethodChannel('zangetsu/novel_http');

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
  await openBoxSafely(AuthCubit.cacheBoxName);
  await ProviderDownloader.init();

  // Appwrite first (no network on construct) — kept for mintJwt (the
  // legacy-session-migration path in MigrationBridge/AuthCubit).
  sl.registerSingleton<AppwriteService>(AppwriteService());
  // Supabase is already Supabase.initialize()d in main.dart; this is just the
  // thin client wrapper the stores/services depend on.
  sl.registerSingleton<SupabaseService>(SupabaseService());
  sl.registerLazySingleton<TvPairingService>(
    () => TvPairingService(sl<SupabaseService>()),
  );
  // Resolved lazily at call time; null when signed out so the stores stay
  // local-only.
  String? currentUserId() => sl<SupabaseService>().currentUserId();

  // Client half of the invisible Appwrite→Supabase account migration. Wired
  // with real closures here (not in migration_bridge.dart) so the bridge
  // itself stays Supabase-type-free and unit-testable.
  sl.registerSingleton<MigrationBridge>(
    MigrationBridge(
      invoke: (name, body) async {
        final r = await sl<SupabaseService>()
            .client
            .functions
            .invoke(name, body: body);
        return (r.data as Map).cast<String, dynamic>();
      },
      signInPassword: (email, pw) async {
        try {
          await sl<SupabaseService>()
              .client
              .auth
              .signInWithPassword(email: email, password: pw);
          return sl<SupabaseService>().client.auth.currentUser != null;
        } catch (_) {
          return false;
        }
      },
      verifyOtp: (email, token) async {
        try {
          await sl<SupabaseService>().client.auth.verifyOTP(
                email: email,
                token: token,
                type: OtpType.email,
              );
          return sl<SupabaseService>().client.auth.currentUser != null;
        } catch (_) {
          return false;
        }
      },
    ),
  );

  await ResumeStore.init();
  sl.registerSingleton<ResumeStore>(ResumeStore());
  await ReadStore.init();
  sl.registerSingleton<ReadStore>(ReadStore());
  await WatchHistory.init();
  sl.registerSingleton<WatchHistory>(
    WatchHistory(sl<SupabaseService>(), currentUserId),
  );
  await ReadHistory.init();
  sl.registerSingleton<ReadHistory>(
    ReadHistory(sl<SupabaseService>(), currentUserId),
  );
  sl.registerSingleton<WatchRoomService>(WatchRoomService(sl<SupabaseService>()));
  sl.registerSingleton<WatchTogetherController>(
    WatchTogetherController(sl<WatchRoomService>()),
  );
  // ListStatusStore is registered BEFORE MyListStore so the latter can wire the
  // status read/hydrate seams straight to it (keeps My List's cloud row + the
  // deliberately-local status store in sync without either importing the other).
  await ListStatusStore.init();
  sl.registerSingleton<ListStatusStore>(ListStatusStore());
  // User-made categories for My List. Its own box, beside the status store and
  // for the same reason: a cloud pull clears the list box, and a category must
  // not go with it.
  await CategoryStore.init();
  sl.registerSingleton<CategoryStore>(
    CategoryStore(
      remote: CategoryRemote(sl<SupabaseService>()),
      currentUserId: currentUserId,
    ),
  );
  await MyListStore.init();
  sl.registerSingleton<MyListStore>(
    MyListStore(
      sl<SupabaseService>(),
      currentUserId,
      statusOf: (m) => sl<ListStatusStore>().statusOf(m)?.name,
      onStatusPulled: (key, name) =>
          sl<ListStatusStore>().setStatusRaw(key, name),
    ),
  );
  await TitlePrefsStore.init();
  sl.registerSingleton<TitlePrefsStore>(TitlePrefsStore());
  await PlaybackPrefs.init();
  sl.registerSingleton<PlaybackPrefs>(PlaybackPrefs());
  await ReaderPrefs.init();
  sl.registerSingleton<ReaderPrefs>(ReaderPrefs());
  await ReaderOverrideStore.init();
  sl.registerSingleton<ReaderOverrideStore>(ReaderOverrideStore());
  // Apply the saved accent colour before the first frame (default = coral).
  await ThemeController.init();
  await DownloadPrefs.init();
  sl.registerSingleton<DownloadPrefs>(DownloadPrefs());
  await TorrentPrefs.init();
  sl.registerSingleton<TorrentPrefs>(TorrentPrefs());
  sl.registerSingleton<TorrentService>(TorrentService());
  sl.registerSingleton<TorrentDownloadService>(TorrentDownloadService());
  await SearchHistory.init();
  sl.registerSingleton<SearchHistory>(SearchHistory());
  await AnimationPrefs.init(); // list/grid reveal toggle (phone/iOS only)
  await IncognitoMode.init(); // privacy: pause history/tracking/RPC when on
  await PinnedSources.init(); // favourite sources pinned atop the source picker
  await SearchSourcePrefs.init();
  sl.registerSingleton<SearchSourcePrefs>(SearchSourcePrefs());
  await NovelLangPrefs.init(); // which languages show in the LNReader catalog
  sl.registerSingleton<NovelLangPrefs>(NovelLangPrefs());
  // Same idea for the Mihon/Aniyomi catalogs (ISO-code langs, separate boxes).
  final mangaLangPrefs = MangaLangPrefs();
  await mangaLangPrefs.init();
  sl.registerSingleton<MangaLangPrefs>(mangaLangPrefs);
  final animeLangPrefs = AnimeLangPrefs();
  await animeLangPrefs.init();
  sl.registerSingleton<AnimeLangPrefs>(animeLangPrefs);
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
  // Pass the AniList token (lazily — AniListService is registered below) so the
  // enrichment's searches authenticate; AniList now 403s anonymous API calls.
  sl.registerSingleton<MetadataEnrichment>(
      MetadataEnrichment(dio, () => sl<AniListService>().store.token));

  // Per-episode descriptions for the episode list (AniZip for anime, TMDB
  // season for movie-source TV series). Best-effort; shares the TMDB-keyed dio.
  sl.registerSingleton<EpisodeMetadataService>(EpisodeMetadataService(dio));

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
  // Manual match corrections (the sync sheet's "Change match"): show → chosen
  // tracker entry id, persisted so a fixed match sticks.
  await TrackerBindingStore.init();
  sl.registerSingleton<TrackerBindingStore>(TrackerBindingStore());
  // TV relay: packs/unpacks tracker sessions to move a login from phone to TV.
  sl.registerLazySingleton<TrackerRelay>(() => TrackerRelay({
        'anilist': sl<AniListService>(),
        'mal': sl<MalService>(),
        'simkl': sl<SimklService>(),
      }));

  // Share deep links (zangetsu://open?…): opens a shared title's Detail, or
  // reports an uninstalled source. Eager so its AppLinks listener is live from
  // boot; navigation is deferred until the root Navigator exists.
  sl.registerSingleton<OpenLinkService>(OpenLinkService());

  // AuthCubit is global so any widget can gate on login. SupabaseService,
  // AppwriteService (mintJwt for migration) and MigrationBridge are already
  // registered above.
  sl.registerSingleton<AuthCubit>(
    AuthCubit(sl<SupabaseService>(), sl<AppwriteService>(), sl<MigrationBridge>()),
  );

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

  // Mihon manga-extension registry — the manga twin of AniyomiManager above,
  // populated by the guarded boot step further down.
  //
  // The singleton itself is registered on EVERY platform: it's an in-memory
  // map that touches no channel, so registering it unconditionally means
  // `sl<MihonManager>()` can never throw and no caller needs an isRegistered
  // dance. The Android gate lives on the boot step instead (see below) — the
  // only place BOOT constructs a MihonProvider. One check there covers
  // everything downstream: nothing loads, so nothing registers, so the source
  // picker lists nothing, and every `mihon:` data call fails to resolve.
  // (MihonExtensionService.installFromRepo also constructs providers and is
  // deliberately NOT gated — like the anime path, its native call throws first
  // off-Android and its own try/catch degrades that to `[]`.)
  final mihonManager = MihonManager();
  sl.registerSingleton<MihonManager>(mihonManager);

  // LNReader novel-extension registry — the novel twin of MihonManager above.
  // Unlike Mihon, LNReader plugins are plain JS (no native APK/DEX), so there's
  // no Platform.isAndroid gate here — same reasoning as the JS provider path.
  // `lnrManager.init()` only opens the `lnreader_plugins` Hive box; it deliberately
  // never builds the ~450KB QuickJS runtime (see LnReaderManager's doc comment)
  // — that only happens lazily the first time a `lnr:` source's data method runs.
  // httpGet/fetch reuse the app's shared `dio` (8s timeout + browser UA already
  // set above) rather than standing up a second HTTP client.
  final lnrService = LnReaderExtensionService(
    httpGet: (url) async {
      final res = await dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      return res.data ?? '';
    },
  );
  final lnrManager = LnReaderManager(
    service: lnrService,
    fetch: (url, init) async {
      // Send LNReader's own browser-like header block UNDER the plugin's
      // headers. Some novel hosts (webnovel.com) sit behind Cloudflare's
      // bot-fight, which 403s a bare request that doesn't look like a browser
      // — it's not a real challenge to solve, just a fingerprint check. The
      // real LNReader app passes these same headers and works with no CF
      // solver at all. Plugin headers win the merge (WebNovel sets its own
      // desktop-Chrome UA).
      final pluginHeaders = init['headers'] is Map
          ? Map<String, dynamic>.from(init['headers'] as Map)
          : const <String, dynamic>{};
      final mergedHeaders = {..._lnreaderBrowserHeaders, ...pluginHeaders};
      final method = (init['method'] as String?)?.toUpperCase() ?? 'GET';

      // Native HTTP first on mobile: headers alone don't get past
      // webnovel.com's Cloudflare check (confirmed on-device — still 403 with
      // the block above), because that gate is on the TLS fingerprint, not the
      // request shape. The native stacks present a browser-like fingerprint
      // that gets through — OkHttp/Conscrypt on Android, URLSession on iOS.
      // Any failure here (missing channel, thrown exception, desktop/web/tests)
      // just falls through to the same Dio request that ran before this existed.
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          final res = await _novelHttp.invokeMapMethod<String, dynamic>(
            'request',
            {
              'url': url,
              'method': method,
              'headers': mergedHeaders.map(
                (k, v) => MapEntry(k, v.toString()),
              ),
              'body': init['body'] is String
                  ? init['body'] as String
                  : init['body']?.toString(),
            },
          );
          if (res != null) {
            return LnReaderHttpResponse(
              status: (res['status'] as num?)?.toInt() ?? 0,
              body: res['body'] as String? ?? '',
              url: res['url'] as String? ?? url,
              headers: res['headers'] is Map
                  ? (res['headers'] as Map).map(
                      (k, v) => MapEntry(k.toString(), v.toString()),
                    )
                  : const {},
            );
          }
        } catch (_) {
          // Fall through to Dio below.
        }
      }

      final res = await dio.request<String>(
        url,
        data: init['body'],
        options: Options(
          method: method,
          headers: mergedHeaders,
          responseType: ResponseType.plain,
          // fetch() never throws on a non-2xx status — it resolves with the
          // response so the plugin can inspect it. Without this Dio would
          // throw on e.g. a 404, which the plugin never gets a chance to see.
          validateStatus: (_) => true,
        ),
      );
      return LnReaderHttpResponse(
        status: res.statusCode ?? 0,
        body: res.data ?? '',
        url: res.realUri.toString(),
        // Dio hands back a list per header (a name may repeat); join them the
        // way HTTP does rather than keeping only the first.
        headers: res.headers.map.map(
          (k, v) => MapEntry(k, v.join(', ')),
        ),
      );
    },
  );
  sl.registerSingleton<LnReaderExtensionService>(lnrService);
  sl.registerSingleton<LnReaderManager>(lnrManager);
  await lnrManager.init();
  // Repo-URL box too, so Backup's sync build() can read it any time — the
  // novel twin of the mihon_repos/aniyomi_repos opens below. Unlike those
  // (opened inside a guarded, Android-only microtask), LNReader has no
  // platform gate, so this can just run inline here.
  if (!Hive.isBoxOpen('lnreader_repos')) {
    await openBoxSafely<String>('lnreader_repos');
  }

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
        aniyomi: AniyomiExtensionService(),
        mihon: MihonExtensionService(),
        lnreader: lnrService),
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
        await openBoxSafely<dynamic>(AniyomiExtensionService.installedBoxName);
      }
      // Repo-URL box too, so Backup's sync build() can read it any time.
      if (!Hive.isBoxOpen('aniyomi_repos')) {
        await openBoxSafely<String>('aniyomi_repos');
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

  // Guarded Mihon boot step — the manga twin of the Aniyomi step above.
  // Same shape: its own microtask so it never blocks startup, and a try/catch
  // so any failure is logged and never propagates.
  //
  // Two things this step is load-bearing for beyond reloading extensions:
  //
  //  1. It OPENS the `mihon_installed` box. MihonExtensionService.installFromRepo
  //     only persists `pkg -> apkPath` when that box is open, so without this
  //     an install would "succeed" and then silently vanish on the next launch
  //     — no error anywhere. The box is opened BEFORE the isEmpty early-return
  //     so a first-ever install still has somewhere to write.
  //  2. It is the single Platform.isAndroid gate for the whole Mihon stack.
  //     MihonProvider deliberately carries no in-provider guards (the anime
  //     twin's are dead code — a missing channel already degrades to empty),
  //     so the check lives here, where it covers boot-reload, the source
  //     picker's listing, and every data call in one place: on iOS nothing is
  //     ever loaded, so no MihonProvider is ever constructed.
  Future.microtask(() async {
    if (!Platform.isAndroid) return; // Mihon extensions are Android-only (DEX)
    try {
      if (!Hive.isBoxOpen(MihonExtensionService.installedBoxName)) {
        await openBoxSafely<dynamic>(MihonExtensionService.installedBoxName);
      }
      // Repo-URL box too, so Backup's sync build() can read it any time.
      if (!Hive.isBoxOpen('mihon_repos')) {
        await openBoxSafely<String>('mihon_repos');
      }
      final box = Hive.box<dynamic>(MihonExtensionService.installedBoxName);
      if (box.isEmpty) {
        return; // nothing installed yet
      }
      final support = await getApplicationSupportDirectory();
      final mihonDir = Directory('${support.path}/mihon');
      final service = MihonExtensionService();
      await service.loadInstalled(mihonDir.path);
      final sources = await service.listSources();
      final providers = sources.map((s) => MihonProvider(info: s)).toList();
      mihonManager.registerAll(providers);
      // Honor a saved `mihon:` active source (the user quit while in manga
      // mode) that wasn't loaded yet at boot. reapplySaved only swaps when the
      // saved id is now valid and never resets an already-restored source, so
      // this composes cleanly with the Aniyomi and CloudStream steps.
      if (sl.isRegistered<ActiveSourceCubit>()) {
        final showNsfw = sl.isRegistered<PlaybackPrefs>()
            ? sl<PlaybackPrefs>().nsfwSources
            : false;
        final changed = sl<ActiveSourceCubit>().reapplySaved((id) {
          final p = mihonManager.get(id);
          if (p == null) return false;
          if (p.info.nsfw && !showNsfw) return false;
          return true;
        });
        if (changed && sl.isRegistered<HomeCubit>()) {
          sl<HomeCubit>().load(); // reload Home for the restored source
        }
      }
    } catch (e, st) {
      debugPrint('[mihon] boot step failed (non-fatal): $e\n$st');
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
      // Valid ids = JS providers + LNReader novel sources (both load on the
      // boot path — lnrManager.installedSources is synchronous). CloudStream,
      // Aniyomi and Mihon load off the boot path, so a saved `cs:`/`ani:`/
      // `mihon:` active source is restored a moment later via reapplySaved
      // rather than being in this initial set. lnr had neither, so a saved
      // novel source fell back to allanime on every restart — include it here.
      valid: {
        ...manager.installedIds,
        ...csManager.all.map((p) => p.sourceId),
        ...lnrManager.installedSources.map((s) => s.id),
      },
    ),
  );

  // App-wide content mode (anime/manga/novel), persisted, with a separate
  // remembered active source per mode so switching modes never disturbs the
  // anime source pick. Registered right after ActiveSourceCubit since it
  // wraps it.
  sl.registerSingleton<ContentModeCubit>(
    await ContentModeCubit.create(sl<ActiveSourceCubit>()),
  );

  sl.registerSingleton<SourceRepository>(
    SourceRepository(
      manager: manager,
      csManager: csManager,
      aniManager: aniyomiManager,
      mihonManager: mihonManager,
      lnrManager: lnrManager,
      activeSource: sl<ActiveSourceCubit>(),
      prefs: sl<PlaybackPrefs>(),
      // The language sets the sources screens already filter their lists by.
      // Without these the repo hands search every language a multi-language
      // extension installs, so choosing English still returned Hebrew.
      mangaLangs: mangaLangPrefs,
      animeLangs: animeLangPrefs,
    ),
  );

  // Now that SourceRepository can enumerate loaded sources, make sure the
  // restored content mode points at a source that belongs to it (e.g. a
  // novel-mode launch shouldn't show an anime source). No-op for anime mode
  // and for any already-correct pick. Mihon (manga) loads async and is handled
  // by its own reapply step below; lnr (novel) is already loaded here.
  sl<ContentModeCubit>().ensureSourceForMode();

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
