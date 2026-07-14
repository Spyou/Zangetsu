import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle, PlatformException;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/hls.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/skip_service.dart';
import '../../core/playback/subtitle_language.dart';
import '../../core/torrent/torrent_prefs.dart';
import '../../core/torrent/torrent_service.dart';
import '../../core/torrent/torrent_util.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/watch_history.dart';
import '../../core/playback/subtitle_download_service.dart';
import '../../core/repository/source_repository.dart';
import '../watch_together/model/room_state.dart';

/// Immutable view-state for the player screen: exactly the fields the UI
/// rebuilds on. These used to drive `notifyListeners()` on the old
/// `ChangeNotifier`; they are now emitted by [PlayerCubit].
///
/// Live playback values (position/playing/buffering/duration) are NOT here —
/// the screen still binds those directly off `player.stream.*` so the engine
/// behaviour is untouched.
class PlayerState extends Equatable {
  const PlayerState({
    this.loadingSources = false,
    this.error,
    this.sources = const [],
    this.active,
    this.qualities = const [],
    this.activeQuality,
    this.currentIndex = 0,
    this.tracks = const Tracks(),
    this.torrentPhase,
  });

  /// True while sources for the current episode are being resolved.
  final bool loadingSources;

  /// Non-null when sources couldn't be resolved/played (drives the retry UI).
  final String? error;

  /// Resolved sources for the current episode.
  final List<VideoSource> sources;

  /// The source currently opened in the engine.
  final VideoSource? active;

  /// HLS-master quality variants (empty unless a multi-variant master exists).
  final List<HlsVariant> qualities;

  /// Selected HLS variant; null = Auto (the adaptive master).
  final HlsVariant? activeQuality;

  /// Index into the episode list of the currently-open episode.
  final int currentIndex;

  /// Available audio/sub/video tracks for the open media (driven by
  /// `player.stream.tracks`).
  final Tracks tracks;

  /// Non-null while a torrent source is being prepared — the human status to
  /// show as a buffering overlay ("Finding peers…", "Buffering 12%"). Null for
  /// every non-torrent source, so normal playback is unaffected.
  final String? torrentPhase;

  PlayerState copyWith({
    bool? loadingSources,
    String? Function()? error,
    List<VideoSource>? sources,
    VideoSource? Function()? active,
    List<HlsVariant>? qualities,
    HlsVariant? Function()? activeQuality,
    int? currentIndex,
    Tracks? tracks,
    String? Function()? torrentPhase,
  }) => PlayerState(
    loadingSources: loadingSources ?? this.loadingSources,
    error: error != null ? error() : this.error,
    sources: sources ?? this.sources,
    active: active != null ? active() : this.active,
    qualities: qualities ?? this.qualities,
    activeQuality: activeQuality != null ? activeQuality() : this.activeQuality,
    currentIndex: currentIndex ?? this.currentIndex,
    tracks: tracks ?? this.tracks,
    torrentPhase: torrentPhase != null ? torrentPhase() : this.torrentPhase,
  );

  @override
  List<Object?> get props => [
    loadingSources,
    error,
    sources,
    active,
    qualities,
    activeQuality,
    currentIndex,
    tracks,
    torrentPhase,
  ];
}

/// Owns a media_kit [Player] for one watch session: opens a source with its
/// headers + subtitles, persists resume position, advances on completion, and
/// falls through to the next source if one fails to start (covers dead/DRM
/// sources).
class PlayerCubit extends Cubit<PlayerState> {
  PlayerCubit({
    required this.sourceId,
    required this.episodes,
    required this.resume,
    required Future<List<VideoSource>> Function(String episodeUrl)
    resolveSources,
    required Dio dio,
    this.history,
    this.showTitle,
    this.cover,
    this.coverHeaders,
    this.showUrl,
    this.category,
    this.malId,
    this.scrobbleTitle,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.imdbId,
    this.availableCategories = const [],
    this.initialResume = Duration.zero,
  }) : _resolveSources = resolveSources,
       _dio = dio,
       _activeCategory = category ?? 'sub',
       super(const PlayerState());

  final String sourceId;
  // Mutable: switching Sub/Dub on a provider that separates the two by episode
  // DATA (not a /sub//dub/ URL segment) re-fetches the other category's episode
  // list and swaps it in (see [switchCategory]).
  List<Episode> episodes;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) _resolveSources;
  final Dio _dio;

  // Optional show-context for writing the Continue Watching history feed.
  final WatchHistory? history;
  final String? showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String? showUrl;

  /// MyAnimeList id for the show (anime), when known. Drives AniList
  /// auto-scrobble: each episode is pushed once it crosses 92%.
  final int? malId;

  /// Anime title used to resolve the AniList entry when [malId] is absent (old
  /// provider / AllAnime). Non-null only for anime — gates scrobbling.
  final String? scrobbleTitle;

  /// TMDB id (movies/series) for Simkl tracking; [tmdbIsTv] selects namespace.
  final int? tmdbId;
  final bool tmdbIsTv;

  /// IMDb id (movies/series) for Simkl tracking when no TMDB id is exposed.
  final String? imdbId;

  /// Episode indices already scrobbled this session (fire once per episode).
  final Set<int> _scrobbled = {};

  /// The category (sub/dub) the session launched in. The LIVE category (which
  /// the user can flip mid-session) is [_activeCategory] — `category` is just
  /// the launch value.
  final String? category;

  /// Sub/Dub categories this title offers (e.g. `['sub','dub']`). When length
  /// <= 1 the player treats the source as single-category (no Version switch).
  /// AllAnime sub/dub are DIFFERENT streams — switching re-resolves the OTHER
  /// category's URL for the current episode (see [_episodeUrl]).
  final List<String> availableCategories;

  /// Fallback resume position from the launch site — the saved position of the
  /// Continue Watching entry the user tapped. Applied only on the first open
  /// and only when the [ResumeStore] lookup MISSES, which happens when a
  /// provider hands back a different opaque episode `data` id than the one we
  /// saved (so the per-episode key no longer matches and we'd start from 0
  /// despite knowing exactly where the user left off). Zeroed after use so
  /// later source/quality switches keep the live position instead.
  Duration initialResume;

  /// Watch Together: `none` for all normal playback (the hooks below are inert).
  RoomRole roomRole = RoomRole.none;

  /// Host-mode only: notified on local play/pause/seek/episode so the room can
  /// broadcast. Null (and never set) outside a room — zero effect on normal use.
  void Function(String event, Duration pos)? onLocalPlayback;

  /// The currently-playing category. Re-resolving sources rewrites the
  /// episode URL's `/sub/` ↔ `/dub/` segment to this. Persisted per-title.
  String _activeCategory;

  final Player player = Player();
  late final VideoController videoController = VideoController(
    player,
    configuration: VideoControllerConfiguration(
      // Pin hardware decoding (media_kit's default, made explicit) — smoother
      // high-res playback + less battery/heat. media_kit auto-falls back to
      // software decode if the device can't hardware-decode a codec.
      enableHardwareAcceleration: true,
      // TV-ONLY: cap the video OUTPUT to 720p. On old TVs the frame is still
      // hardware-decoded, but the weak GPU chokes compositing a full 1080p/4K
      // texture every frame → visible playback lag. Capping the render size is
      // media_kit's documented performance lever ("substantial performance
      // improvements if a small width & height is specified"). Phones are
      // untouched — null keeps full-resolution output as before.
      width: sl<AppMode>().isTv ? 1280 : null,
      height: sl<AppMode>().isTv ? 720 : null,
    ),
  );

  /// Bumped whenever the subtitle style changes (or a source opens). The player
  /// screen listens to rebuild the Video's [SubtitleViewConfiguration] — media_kit
  /// renders text subs via a Flutter overlay, so styling lives there, NOT in
  /// mpv's sub-* properties.
  final ValueNotifier<int> subtitleStyleRev = ValueNotifier<int>(0);

  /// Brief user-facing status (e.g. "Switching server…") the player screen
  /// shows as a transient toast. Auto-clears after a couple of seconds.
  final ValueNotifier<String?> toast = ValueNotifier<String?>(null);
  Timer? _toastTimer;
  void _toast(String msg) {
    toast.value = msg;
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 2), () => toast.value = null);
  }

  /// One-shot mpv tuning, started on first access and awaited before every
  /// [_open]. Must complete BEFORE `player.open` or its demuxer options (e.g.
  /// the HLS fake-extension relaxation) don't apply to the file being opened.
  late final Future<void> _mpvConfigured = _configureMpv();

  VideoSource?
  _hlsMaster; // the HLS master among `sources` that the quality menu expands

  final List<StreamSubscription> _subs = [];
  Duration _lastPos = Duration.zero;
  Duration _lastDur = Duration.zero;
  // The resume position we still need to reach. Set when a resume mark is
  // applied on open and cleared once playback actually reaches it. While set, a
  // re-open (e.g. the default-quality switch that fires right after resume, when
  // _lastPos has only crept to ~1s) must keep targeting it instead of dropping
  // back to the couple of seconds buffered so far — otherwise resume is lost.
  Duration _pendingResume = Duration.zero;
  // Glitch guard: the last ACCEPTED position + its wall-clock, so we can reject
  // a spurious forward jump (some remote MP4s emit a garbage position mid-seek;
  // saving it corrupts the mark and makes the title un-resumable). Plus the time
  // of the last USER seek, which is a legitimate jump we must not reject.
  Duration _goodPos = Duration.zero;
  int _goodPosMs = 0;
  int _userSeekMs = 0;
  int _lastResumeSeekMs = 0; // throttle for the resume re-seek (anti-thrash)
  int _lastHistoryMs = 0; // throttle: last wall-clock ms we wrote progress
  int _gen = 0; // bumped per open; async continuations bail if superseded
  final Set<String> _tried = {}; // source URLs already attempted this episode
  bool _recovering = false; // debounce: one error-recovery at a time
  // True once the current source has actually produced playback (position
  // advanced). libmpv emits transient "connection"/"failed to open" warnings
  // mid-stream (HLS segment blips, a failed subtitle track) even while video +
  // audio play fine — once a source is playing we must NOT treat those as a
  // reason to cycle sources (which spuriously showed "No source could be
  // played" over working playback and broke the watch-progress scrobble).
  bool _startedThisSource = false;
  // Stall watchdog: a STARTED source that dies/stalls mid-playback (dead host,
  // pulled segment) buffers forever — _onPlaybackError won't cycle it (it bails
  // once started). When buffering persists with no position progress we fail
  // over to the next untried mirror at the same position.
  Timer? _stallTimer;
  Duration _stallAnchorPos = Duration.zero;
  // Streams served by a local proxy (127.0.0.1 — Aniyomi's Cloudflare video
  // proxy) buffer on seek while the proxy re-fetches segments through the source
  // client; that's expected, not a dead source, so the stall watchdog is skipped
  // for them (mirrors the torrent exemption handled via _activeTorrentId).
  bool _isProxiedStream = false;
  // Start watchdog for a DIRECT Aniyomi source: a Cloudflare-walled stream fails
  // to start without emitting a clean mpv error (it just hangs), so the normal
  // error-based failover never fires. If a direct Aniyomi source hasn't started
  // within ~10s we fail over — pickDefault then auto-selects the higher-ranked
  // "· proxy" version of the same quality. Aniyomi-only + direct-only, so
  // CloudStream / JS / torrent sources are completely unaffected.
  Timer? _startTimer;
  // Fired once per session: mark the anime CURRENT on AniList as soon as
  // playback starts (so "started watching" shows immediately, not only after
  // an episode crosses the 92% scrobble threshold).
  bool _markedWatching = false;
  bool _defaultRateApplied = false; // default speed applied once per session

  Episode get currentEpisode => episodes[state.currentIndex];

  /// Stable per-show key for resume (the show URL, falling back to sourceId) so
  /// episodes with the same id across different shows don't collide.
  String get _showKey => showUrl ?? sourceId;

  /// The episode URL to resolve sources from, rewritten to the active
  /// category. Sub/Dub are separate AllAnime streams encoded in the URL
  /// (`allanime://<id>/sub/<n>` vs `.../dub/<n>`), so switching language means
  /// resolving the OTHER category's URL. Only rewrites when the title offers
  /// more than one category AND the URL carries a `/sub/` or `/dub/` segment
  /// (NetMirror etc. have no such segment → unchanged).
  String _episodeUrl(Episode ep) {
    if (availableCategories.length > 1 &&
        RegExp(r'/(sub|dub)/').hasMatch(ep.url)) {
      return ep.url.replaceFirst(RegExp(r'/(sub|dub)/'), '/$_activeCategory/');
    }
    return ep.url;
  }

  // ── Sub/Dub (category) switching — the player owns this now (not Detail) ──

  /// Categories this title offers (drives the player's "Version" section).
  List<String> get categories => availableCategories;

  /// The currently-active category ('sub'/'dub').
  String get activeCategory => _activeCategory;

  /// Switch the whole session to [cat] (sub ↔ dub). No-op when unchanged or
  /// not offered. Re-resolves the CURRENT episode in the new language while
  /// preserving the live position and current index, persists the per-title
  /// choice, and keeps the rest of the session (incl. playNext) + history in
  /// [cat].
  Future<void> switchCategory(String cat) async {
    if (cat == _activeCategory || !availableCategories.contains(cat)) return;
    _activeCategory = cat;
    await sl<TitlePrefsStore>().setCategory(sourceId, showUrl ?? '', cat);

    // Re-resolve the current episode in the new language — like openEpisode but
    // keeping currentIndex and the live position.
    final gen = ++_gen;
    final keepPos = _lastPos;
    _tried.clear();
    _recovering = false;
    emit(
      state.copyWith(
        error: () => null,
        loadingSources: true,
        sources: const [],
        active: () => null,
      ),
    );
    try {
      // Resolve the episode URL for the new language. For providers that encode
      // sub/dub in the URL (e.g. AllAnime `.../sub/1`) the rewrite below is
      // enough. Providers that keep SEPARATE episode lists per language (e.g.
      // CloudStream AniKoto — different opaque `data` per episode) leave the URL
      // unchanged; for those, re-fetch the other category's episode list and use
      // the matching episode's data, otherwise dub would just replay the sub.
      var epUrl = _episodeUrl(currentEpisode);
      if (epUrl == currentEpisode.url &&
          (showUrl?.isNotEmpty ?? false)) {
        final catEps = await sl<SourceRepository>()
            .episodes(showUrl!, sourceId: sourceId, category: cat);
        if (gen != _gen) return;
        if (state.currentIndex < catEps.length) {
          episodes = catEps;
          epUrl = catEps[state.currentIndex].url;
        }
      }
      final resolved = await _resolveSources(epUrl);
      if (gen != _gen) return;
      emit(state.copyWith(sources: resolved, loadingSources: false));
      _buildQualityMenu(gen);
      final pick = pickDefault(resolved);
      if (pick == null) {
        emit(
          state.copyWith(error: () => 'No playable sources for this episode.'),
        );
        return;
      }
      await _open(pick, seekTo: keepPos, gen: gen);
      _applyDefaultQuality();
    } catch (e) {
      if (gen != _gen) return;
      emit(
        state.copyWith(
          loadingSources: false,
          error: () => 'Could not load sources: $e',
        ),
      );
    }
  }

  /// mpv HTTP tuning so remote MP4s (e.g. 4khdhub file hosts) seek/resume
  /// reliably: force-seekable treats them as seekable even when the host omits
  /// Accept-Ranges, and the reconnect options recover the connection that many
  /// hosts drop on a seek (which otherwise restarts playback at 0). HLS already
  /// seeks fine; this is what lets the MP4 mirrors behave like they do in
  /// ExoPlayer-based apps.
  Future<void> _configureMpv() async {
    final p = player.platform;
    if (p is NativePlayer) {
      try {
        await p.setProperty('force-seekable', 'yes');
        await p.setProperty(
          'stream-lavf-o',
          'reconnect=1,reconnect_streamed=1,'
              'reconnect_on_network_error=1,reconnect_delay_max=5',
        );
        // HLS workarounds for anti-leech CDNs (AnimeSalt/AnimixStream, …):
        //  • extension_picky=0 + allowed_extensions=ALL — segments are disguised
        //    with non-media extensions (.js/.css/.woff); FFmpeg 7 otherwise
        //    rejects them by URL extension (segment bytes are still validated).
        //  • http_persistent=0 — these CDNs break FFmpeg's HLS keepalive
        //    ("keepalive request failed … Invalid argument"), which corrupts the
        //    sub-playlist/segment fetches ("parse_playlist error Invalid data").
        //    Forcing a fresh connection per request fixes playback.
        //  • analyzeduration=2000000 (2s) — cap FFmpeg's pre-play stream probe
        //    so the first frame appears sooner. 2s is ample to detect audio+
        //    video on normal streams; raise it if a source ever loses a track.
        await p.setProperty(
          'demuxer-lavf-o',
          'extension_picky=0,allowed_extensions=ALL,http_persistent=0,'
              'analyzeduration=2000000',
        );
        // ── Anti-buffering: prefetch a LARGE read-ahead. ──────────────────
        // mpv's default read-ahead is ~1s, so any CDN/network dip — made worse
        // by http_persistent=0's per-segment reconnects — stalls playback
        // instantly. Buffering ~30–60s ahead absorbs those dips. Playback still
        // starts as soon as there's enough to begin, then keeps filling ahead,
        // so this doesn't slow startup; ~128 MiB forward buffer is fine on phones.
        await p.setProperty('cache', 'yes');
        await p.setProperty('cache-secs', '60');
        await p.setProperty('demuxer-readahead-secs', '60');
        await p.setProperty('demuxer-max-bytes', '128MiB');
        await p.setProperty('demuxer-max-back-bytes', '48MiB');
        // ── A/V stays in sync after a mid-stream stall. ───────────────────────
        // Symptom this fixes: a movie/episode freezes mid-playback (host throttle
        // or a brief dip — not a visible "buffering"), and on recovery the audio
        // runs AHEAD of the picture. Cause: Android's DIRECT mediacodec decoder
        // freezes its last frame on the output surface during the hiccup while
        // the audio track keeps draining, so audio ends up seconds ahead and
        // mpv's default A/V sync (~0.1s/frame) can't claw it back. COPY mode
        // routes frames through mpv's own pipeline, timed against the audio
        // clock, so it drops/resyncs cleanly after a stall — the robustness
        // ExoPlayer/CloudStream get from decoder fallback + shared-clock
        // renderers. Still hardware-decoded; mpv falls back to software per-codec
        // if a device can't hw-decode it.
        // Decoder is user-selectable (Settings → Playback → Video decoder).
        // Default 'hw' → 'mediacodec-copy' (unchanged); 'sw' → software decode
        // for streams the hardware decoder chokes on.
        await p.setProperty('hwdec', sl<PlaybackPrefs>().hwdecValue);
        // On a cache underrun, pause audio+video together and wait until a little
        // is rebuffered before resuming, so they restart in lock-step instead of
        // audio-ahead (mirrors ExoPlayer's buffer-for-playback-after-rebuffer).
        await p.setProperty('cache-pause', 'yes');
        await p.setProperty('cache-pause-wait', '2');
        // ── In-app volume + boost (CloudStream-style). The gain is a SOFTWARE
        // audio filter (af=volume=N), so a >100% boost is genuinely louder than
        // the source even when the phone's system volume is low. ────────────
        await p.setProperty('volume-max', '200');
        await p.setProperty('volume', '100'); // neutral base — gain is via af
        await p.setProperty('af', _audioFilterChain());
      } catch (_) {}
      // Make the bundled subtitle fonts available to mpv/libass (which can't
      // read Flutter's asset bundle). Fire-and-forget so it never delays the
      // first open; the font picker just works once it's done.
      unawaited(_setupSubtitleFonts(p));
    }
  }

  // Extract-once guard (static: shared across player instances this session).
  static bool _subFontsExtracted = false;

  /// Copy the app's bundled .ttf subtitle fonts to a real on-disk folder and
  /// point mpv/libass at it via `sub-fonts-dir`, so `sub-font` (the Subtitle
  /// style picker) can actually resolve them. Best-effort, never throws.
  Future<void> _setupSubtitleFonts(NativePlayer p) async {
    try {
      final dir = Directory(
        '${(await getApplicationSupportDirectory()).path}/sub_fonts',
      );
      if (!_subFontsExtracted) {
        if (!dir.existsSync()) dir.createSync(recursive: true);
        const fontAssets = <String>[
          'assets/fonts/Inter.ttf',
          'assets/fonts/Poppins-Regular.ttf',
          'assets/fonts/Roboto-Regular.ttf',
          'assets/fonts/OpenSans-Regular.ttf',
          'assets/fonts/Lato-Regular.ttf',
          'assets/fonts/Montserrat-Regular.ttf',
          'assets/fonts/Nunito-Regular.ttf',
          'assets/fonts/Rubik-Regular.ttf',
          'assets/fonts/NotoSans-Regular.ttf',
          'assets/fonts/SourceSans3-Regular.ttf',
        ];
        for (final a in fontAssets) {
          final out = File('${dir.path}/${a.split('/').last}');
          if (!out.existsSync()) {
            try {
              final data = await rootBundle.load(a);
              await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
            } catch (_) {}
          }
        }
        _subFontsExtracted = true;
      }
      // 'auto' → on Android (no fontconfig) libass uses the embedded provider,
      // which scans sub-fonts-dir; the family name in sub-font then matches.
      await p.setProperty('sub-fonts-dir', dir.path);
      await p.setProperty('sub-font-provider', 'auto');
    } catch (_) {}
  }

  void init(int index) {
    // Start mpv tuning now; [_open] awaits it before opening so the options
    // (HLS fake-extension relaxation, reconnect, …) are in effect for the file.
    unawaited(_mpvConfigured);
    emit(state.copyWith(tracks: player.state.tracks));
    _subs.add(
      player.stream.tracks.listen((t) {
        emit(state.copyWith(tracks: t));
        // Tracks just arrived — restore remembered audio/subtitle. When the
        // stream's track list loads AFTER we've applied an external soft sub,
        // mpv can drift off it (auto-select another track / none), silently
        // overriding the preferred language. If the currently-selected sub is
        // no longer the one we chose, re-arm so _tryApplySubPref re-applies it.
        // Guarded on drift (not on every track change) so re-applying a URI sub
        // — which media_kit does via a fresh `sub-add` — can't loop.
        if (_wantedSubId != null &&
            player.state.track.subtitle.id != _wantedSubId) {
          _subApplied = false;
        }
        _tryApplyAudioPref();
        _tryApplySubPref();
      }),
    );
    _subs.add(
      player.stream.position.listen((p) {
        _lastPos = p;
        // Keep the resume target as a FLOOR for re-opens until we're safely past
        // it (NOT the instant it's touched — a re-open firing right then would
        // otherwise lose the floor and snap back to ~0). 15s past = stable.
        if (_pendingResume > Duration.zero &&
            p > _pendingResume + const Duration(seconds: 15)) {
          _pendingResume = Duration.zero;
        }
        // Force the resume seek to actually STICK. Some remote MP4 hosts briefly
        // report the resume position (mpv's `start` property) then reset to 0
        // and play from the beginning — the seek-on-open silently failed, and a
        // one-shot re-seek can be fooled by that transient reading. So while a
        // resume is still pending and we're playing well short of it, re-issue
        // the seek, paced so each range request has time to land (never
        // thrashing). Cleared automatically once playback gets past the target.
        if (_pendingResume > Duration.zero &&
            _lastDur > Duration.zero &&
            _pendingResume < _lastDur &&
            p + const Duration(seconds: 15) < _pendingResume) {
          final nowS = DateTime.now().millisecondsSinceEpoch;
          if (nowS - _lastResumeSeekMs > 2500) {
            _lastResumeSeekMs = nowS;
            player.seek(_pendingResume);
          }
        }
        if (p > Duration.zero) {
          _startedThisSource = true; // source is playing
          _startTimer?.cancel();
          _startTimer = null;
          if (!_markedWatching) {
            _markedWatching = true;
            _markWatching(); // "started watching" → CURRENT on AniList now
          }
        }

        // Throttled progress capture so Continue Watching fills mid-episode
        // (without waiting for an episode switch / dispose). Cheap: at most one
        // write every ~5s. NOT gated on duration — downloaded HLS (concatenated
        // TS) often reports no duration, and we still want resume to work.
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastHistoryMs >= 5000) {
          _lastHistoryMs = now;
          _persist();
        }

        // Seamless binge: once we pass ~85% of the episode, resolve the NEXT
        // episode's stream in the background so advancing is instant. Fires at
        // most once per current episode (re-armed when the index changes).
        final idx = state.currentIndex;
        if (_prefetchedNextForIndex != idx &&
            idx + 1 < episodes.length &&
            _lastDur > Duration.zero &&
            p >= _lastDur * 0.85) {
          _prefetchedNextForIndex = idx;
          sl<SourceRepository>()
              .prefetch(_episodeUrl(episodes[idx + 1]), sourceId: sourceId);
        }
      }),
    );
    _subs.add(
      player.stream.duration.listen((d) {
        _lastDur = d;
        // The duration arriving is mpv's "ready" signal (its STATE_READY): only
        // now is the stream reliably seekable. A remote MP4 reports duration
        // only after its moov atom loads, and any seek issued before that is
        // clamped to 0 — the "always resumes from 0" bug. So apply the pending
        // resume HERE, the moment seeking is possible. (This is how CloudStream
        // does it — re-seek to the saved position on STATE_READY.)
        if (_pendingResume > Duration.zero && d > Duration.zero) {
          if (_pendingResume >= d) {
            // Mark is at/after the end (corrupted/too-large) — can't resume
            // there; drop it so playback + saving proceed normally.
            _pendingResume = Duration.zero;
          } else if (_lastPos < _pendingResume) {
            player.seek(_pendingResume);
          }
        }
        // Re-assert the subtitle preference ONCE at STATE_READY. A soft sub
        // applied during the racy open can end up SELECTED but not rendering
        // (mpv added it before the stream finished loading). Re-applying here —
        // the point where a manual pick reliably renders — forces a fresh
        // `sub-add` so the preferred language actually shows. The duplicate mpv
        // track this creates is hidden from the picker (see mediaSubtitleTracks).
        if (d > Duration.zero && !_subReadyReapplied && _wantedSubId != null) {
          _subReadyReapplied = true;
          _subApplied = false;
          _tryApplySubPref();
        }
        // Fetch accurate OP/ED skip times once the episode length is known.
        if (d > Duration.zero && _skipsForIndex != state.currentIndex) {
          _skipsForIndex = state.currentIndex;
          _fetchSkips(state.currentIndex, d);
        }
      }),
    );
    // Completion is handled by the player screen (it shows the "Up next"
    // countdown card and then advances), so the controller doesn't auto-advance
    // here — avoids double-advancing. We DO use it to force an AniList scrobble
    // (covers HLS streams that report no duration, so the 92% check never fires).
    _subs.add(
      player.stream.completed.listen((done) {
        if (done) _maybeScrobble(force: true);
      }),
    );
    _subs.add(player.stream.error.listen((e) => _onPlaybackError(e)));
    _subs.add(
      player.stream.buffering.listen((buffering) {
        // A torrent local stream buffers while pieces download — that's normal,
        // not a dead source. Arming the stall watchdog would restart the torrent
        // from scratch and churn native memory (force close). Skip it for torrents.
        if (buffering &&
            _startedThisSource &&
            !_recovering &&
            _activeTorrentId == null &&
            !_isProxiedStream) {
          // Started source stalled — arm a watchdog. If we're still stuck and the
          // position hasn't advanced ~18s later, the stream is likely dead → fail
          // over.
          _stallAnchorPos = _lastPos;
          _stallTimer?.cancel();
          _stallTimer = Timer(const Duration(seconds: 18), _failoverFromStall);
        } else {
          _stallTimer?.cancel();
          _stallTimer = null;
        }
      }),
    );
    openEpisode(index);
  }

  // ── Public playback helpers (used by the Netflix-style overlay) ───────────

  void setRate(double r) => player.setRate(r);

  /// Current video-decoder mode ('hw'|'hw+'|'sw'|'auto') — drives the in-player
  /// decoder button label.
  String get decoderMode => sl<PlaybackPrefs>().videoDecoder;

  /// Switch the video decoder AT RUNTIME: mpv re-initialises its decoder in
  /// place, so a stuttering / green / black stream can be fixed WITHOUT leaving
  /// the video. Also persisted as the new default for future opens.
  Future<void> setDecoder(String mode) async {
    await sl<PlaybackPrefs>().setVideoDecoder(mode);
    final p = player.platform;
    if (p is NativePlayer) {
      try {
        await p.setProperty('hwdec', sl<PlaybackPrefs>().hwdecValue);
      } catch (_) {}
    }
  }

  /// Apply a USER-chosen playback speed and persist it — per-title (this
  /// movie/series) AND globally (so new titles start at the same preference).
  /// Best-effort; mirrors [_rememberQuality].
  void setRateRemembered(double r) {
    player.setRate(r);
    final url = showUrl;
    if (url != null && url.isNotEmpty) {
      sl<TitlePrefsStore>().setSpeed(sourceId, url, r);
    }
    sl<PlaybackPrefs>().setDefaultSpeed(r);
  }

  /// True when the local user is a viewer in a Watch Together room (not the
  /// host). When this is the case, local transport actions are suppressed so
  /// the viewer cannot desync from the host's authoritative playback state.
  bool get _isRoomViewer => roomRole == RoomRole.client;

  void togglePlay() {
    if (_isRoomViewer) return;
    final willPlay = !player.state.playing;
    player.playOrPause();
    if (roomRole == RoomRole.host) {
      onLocalPlayback?.call(willPlay ? 'play' : 'pause', _lastPos);
    }
  }
  void seekTo(Duration d) {
    if (_isRoomViewer) return;
    _pendingResume = Duration.zero; // user took control → drop the resume floor
    _markUserSeek(d);
    player.seek(d);
    if (roomRole == RoomRole.host) onLocalPlayback?.call('seek', d);
  }

  /// Seek by [delta] (signed), clamped into 0..duration.
  void seekBy(Duration delta) {
    if (_isRoomViewer) return;
    _pendingResume = Duration.zero; // user took control → drop the resume floor
    final target = _lastPos + delta;
    final dur = _lastDur;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && target > dur ? dur : target);
    _markUserSeek(clamped);
    player.seek(clamped);
    if (roomRole == RoomRole.host) onLocalPlayback?.call('seek', clamped);
  }

  /// Record a deliberate user seek to [target]. Besides flagging the jump as
  /// legitimate, it moves the glitch-guard baseline ([_goodPos]) to the seek
  /// target — otherwise a large but valid seek (e.g. scrubbing 9 min ahead)
  /// looks like a garbage forward jump to [_persist] and gets rejected, so the
  /// new position is never saved and resume snaps back to where you were before
  /// the seek.
  void _markUserSeek(Duration target) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _userSeekMs = now;
    _goodPos = target;
    _goodPosMs = now;
  }

  List<AudioKind> get audioKinds => availableKinds(state.sources);
  AudioKind? get activeKind => state.active?.kind;

  // ── Scrub-preview source (Netflix-style thumbnails) ───────────────────────
  /// The media URL a second, hidden player opens to generate scrub previews.
  String? get previewUri => state.active?.url;

  /// HTTP headers needed to fetch [previewUri] (auth/referer for some mirrors).
  Map<String, String>? get previewHeaders => state.active?.headers;

  /// Whether the active media is a local/offline file (vs. an http stream).
  /// Local previews are instant and free; online ones cost a little data.
  bool get isLocalMedia {
    final u = state.active?.url;
    return u != null && !u.startsWith('http');
  }

  /// Switch to the best source of the given audio [k] (Sub/Dub), preserving
  /// the live position.
  Future<void> switchAudio(AudioKind k) async {
    final s = pickDefault(state.sources, prefer: k);
    if (s != null) await switchSource(s);
  }

  // ── Embedded/soft track selection (CloudStream-style picker) ──────────────
  // Tracks populate after a media opens (driven by player.stream.tracks).

  /// Embedded audio tracks for the open media (excludes the synthetic
  /// auto/no entries media_kit always reports).
  List<AudioTrack> get mediaAudioTracks =>
      state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();

  /// Embedded subtitle tracks for the open media (excludes auto/no). Also
  /// excludes externally `sub-add`ed tracks — a source soft-sub applied via
  /// SubtitleTrack.uri shows up in mpv's track list with its URL as the id,
  /// which would duplicate the entry already listed under source subtitles
  /// (and pile up on every re-apply). Those are surfaced via [softSubs] instead.
  List<SubtitleTrack> get mediaSubtitleTracks => state.tracks.subtitle
      .where((t) =>
          t.id != 'auto' &&
          t.id != 'no' &&
          !t.id.startsWith('http') &&
          !t.id.startsWith('/'))
      .toList();

  /// Currently-selected audio track (id == 'auto'/'no' for the synthetic ones).
  AudioTrack get activeAudioTrack => player.state.track.audio;

  /// Currently-selected subtitle track (id == 'no' when subs are off).
  SubtitleTrack get activeSubtitleTrack => player.state.track.subtitle;

  void setAudioTrack(AudioTrack t) {
    player.setAudioTrack(t);
    final url = showUrl;
    final pref = t.language ?? t.title ?? t.id;
    if (url != null && url.isNotEmpty && pref.isNotEmpty) {
      sl<TitlePrefsStore>().setAudioTrack(sourceId, url, pref);
    }
  }

  bool _audioApplied = false; // remembered audio track restored this episode

  /// Restore the title's remembered embedded audio track once per episode
  /// (multi-audio files). Retried from the tracks stream as tracks load.
  void _tryApplyAudioPref() {
    if (_audioApplied) return;
    final url = showUrl;
    if (url == null) return;
    final pref = sl<TitlePrefsStore>().audioTrack(sourceId, url);
    if (pref == null) {
      _audioApplied = true;
      return;
    }
    final p = pref.toLowerCase();
    for (final t in mediaAudioTracks) {
      if ((t.language ?? '').toLowerCase() == p ||
          (t.title ?? '').toLowerCase() == p) {
        player.setAudioTrack(t);
        _audioApplied = true;
        return;
      }
    }
    // Not loaded yet — retry on the next tracks update.
  }

  void setSubtitle(SubtitleTrack t) {
    player.setSubtitleTrack(t);
    _wantedSubId = t.id;
    // Remember globally by language when we can resolve one; a track we can't
    // classify is a one-off pick that must not set a bad global default.
    final lang = languageOfSource(t.language ?? t.title ?? '');
    if (lang != null) sl<PlaybackPrefs>().setSubtitlePreference(lang.iso1);
  }

  void subtitlesOff() {
    player.setSubtitleTrack(SubtitleTrack.no());
    _wantedSubId = 'no';
    sl<PlaybackPrefs>().setSubtitlePreference('off');
  }

  /// External "soft" subtitles advertised by the active source.
  List<Subtitle> get softSubs => state.active?.subtitles ?? const [];

  /// Load one of the source's soft-subs by URL.
  Future<void> setSoftSub(Subtitle s) async {
    await player.setSubtitleTrack(
      SubtitleTrack.uri(s.url, title: s.label ?? s.lang, language: s.lang),
    );
    _wantedSubId = s.url;
    final lang = languageOfSource(s.lang) ?? languageOfSource(s.label ?? '');
    if (lang != null) sl<PlaybackPrefs>().setSubtitlePreference(lang.iso1);
  }

  /// Load an external subtitle file from disk (picked via file_picker).
  Future<void> setSubtitleFromFile(String path) async {
    await player.setSubtitleTrack(SubtitleTrack.uri(path));
    _wantedSubId = path;
  }

  bool _subApplied = false; // remembered-subtitle restored for this episode
  bool _autoSubDlTried = false; // keyless auto-download fired at most once/episode
  String? _wantedSubId; // id/url of the subtitle we intend to keep selected
  bool _subReadyReapplied = false; // re-asserted the sub pref once at STATE_READY

  /// Restore the title's remembered subtitle once per episode. 'off' turns subs
  /// off; otherwise match a soft-sub or embedded track by language/label.
  /// Embedded tracks load after open, so this is retried from the tracks stream
  /// until a match is found (or there's nothing to restore).
  void _tryApplySubPref() {
    if (_subApplied) return;
    final prefRaw = sl<PlaybackPrefs>().subtitlePreference;

    // 'off' → subtitles off on every video.
    if (prefRaw == 'off') {
      player.setSubtitleTrack(SubtitleTrack.no());
      _wantedSubId = 'no';
      _subApplied = true;
      return;
    }
    // '' (Auto) → don't force anything.
    if (prefRaw.isEmpty) {
      _wantedSubId = null;
      _subApplied = true;
      return;
    }
    // A language code → source subtitle first, then embedded, then download.
    final prefLang = languageByPref(prefRaw);
    if (prefLang == null) {
      _subApplied = true;
      return;
    }
    final soft = pickPreferredSub(softSubs, prefLang);
    if (soft != null) {
      player.setSubtitleTrack(
        SubtitleTrack.uri(soft.url, title: soft.label ?? soft.lang, language: soft.lang),
      );
      _wantedSubId = soft.url;
      _subApplied = true;
      return;
    }
    for (final t in mediaSubtitleTracks) {
      final tLang = t.language ?? '';
      final tTitle = t.title ?? '';
      if (matchesSourceLang(tLang, prefLang) || matchesSourceLang(tTitle, prefLang)) {
        player.setSubtitleTrack(t);
        _wantedSubId = t.id;
        _subApplied = true;
        return;
      }
    }
    // No source/embedded match — embedded tracks may still be loading; leave
    // _subApplied false so the tracks-stream retry re-checks. Fire the keyless
    // auto-download at most once per episode.
    final titleForSub = showTitle ?? scrobbleTitle;
    if (!_autoSubDlTried &&
        sl<PlaybackPrefs>().autoDownloadSubtitles &&
        (imdbId?.isNotEmpty == true ||
            tmdbId != null ||
            (titleForSub?.isNotEmpty == true))) {
      _autoSubDlTried = true;
      _fetchAndApplySubtitle(prefLang, title: titleForSub);
    }
  }

  /// Re-run the global subtitle preference against the current video (used by
  /// the in-player / Settings picker so a change applies immediately).
  void reapplyPreferredSubtitle() {
    _subApplied = false;
    _autoSubDlTried = false;
    _tryApplySubPref();
  }

  /// Keyless auto-download fallback. Calls [SubtitleDownloadService.find] with
  /// the title's imdb/tmdb id (or show title for id-less content) and the
  /// user's preferred language. On success, loads the first result directly
  /// from its remote URL via [SubtitleTrack.uri] — no temp-file step needed.
  /// Fully fire-and-forget: any error is silently swallowed so playback is
  /// never disrupted.
  void _fetchAndApplySubtitle(Language lang, {String? title}) {
    final epNum = currentEpisode.number?.toInt();
    // Capture gen so stale completions after an episode change are discarded.
    final capturedGen = _gen;
    unawaited(
      Future(() async {
        try {
          final subs = await SubtitleDownloadService().find(
            imdbId: imdbId,
            tmdbId: tmdbId,
            isTv: tmdbIsTv,
            // The Episode model carries no season, so assume season 1 for TV —
            // correct for single-season shows and season-relative episode lists;
            // a mismatch just yields no result (never a wrong-episode sub).
            season: tmdbIsTv ? 1 : null,
            episode: tmdbIsTv ? epNum : null,
            title: title,
            iso2: lang.iso2,
            iso1: lang.iso1,
          );
          // Discard if the user moved to a different episode or a track was
          // already matched by the time the response arrived.
          if (capturedGen != _gen || _subApplied || subs.isEmpty) return;
          await player.setSubtitleTrack(
            SubtitleTrack.uri(
              subs.first.url,
              title: lang.name,
              language: lang.iso2,
            ),
          );
          _wantedSubId = subs.first.url;
          _subApplied = true;
        } catch (_) {
          // Silently ignored — playback continues without subtitles.
        }
      }),
    );
  }

  // Online subtitle search/download is wired in the player UI via
  // SubtitleSearchService (OpenSubtitles); results apply through
  // setSubtitleFromFile. Full subtitle styling + delay/sync are handled above.

  /// Resolves sources for [index] and starts the best one.
  /// [fromRoom] bypasses the viewer lock so the room can move viewers to the
  /// host's episode; all other callers leave it false so viewer taps stay blocked.
  Future<void> openEpisode(int index, {bool fromRoom = false}) async {
    if (_isRoomViewer && !fromRoom) return;
    final gen = ++_gen;
    await _persist(flush: true);
    // Only drop the pending resume when actually switching episodes — a
    // same-episode re-open (recovery/failover) must keep targeting it.
    if (index != state.currentIndex) _pendingResume = Duration.zero;
    _tried.clear();
    _recovering = false;
    _skips = const []; // clear previous episode's skip markers
    _skipsForIndex = -1; // refetched when the new duration arrives
    _prefetchedNextForIndex = -1; // re-arm next-episode prefetch for the new ep
    _subApplied = false; // restore the remembered subtitle for the new episode
    _autoSubDlTried = false; // re-arm keyless auto-download for the new episode
    _wantedSubId = null; // clear the intended-sub tracking for the new episode
    _subReadyReapplied = false; // re-arm the STATE_READY sub re-assert
    _audioApplied = false; // restore the remembered audio track too
    emit(
      state.copyWith(
        currentIndex: index,
        error: () => null,
        loadingSources: true,
        sources: const [],
        active: () => null,
      ),
    );
    try {
      final resolved = await _resolveSources(_episodeUrl(currentEpisode));
      if (gen != _gen) return; // superseded by a newer open
      emit(state.copyWith(sources: resolved, loadingSources: false));
      _buildQualityMenu(
        gen,
      ); // populate Auto/1080p/720p from the HLS master, if any
      // Prefer the source the user picked for this title (e.g. Hindi), else the
      // adaptive default.
      final pick = _preferredSource(resolved) ?? pickDefault(resolved);
      if (pick == null) {
        emit(
          state.copyWith(error: () => 'No playable sources for this episode.'),
        );
        return;
      }
      await _open(pick, gen: gen);
      _applyDefaultQuality();
      if (roomRole == RoomRole.host) onLocalPlayback?.call('episode', Duration.zero);
    } catch (e) {
      if (gen != _gen) return;
      emit(
        state.copyWith(
          loadingSources: false,
          error: () => 'Could not load sources: $e',
        ),
      );
    }
  }

  /// Applies the user's [PlaybackPrefs.defaultQuality] over the adaptive default
  /// that [_open] just started. Defensive: a no-op when nothing matches (never
  /// throws), so 'auto' or an unavailable target keeps the current default.
  ///
  /// 'highest' selects the top HLS variant if any exist, else the top per-source
  /// quality. '1080p'/'720p'/'480p' select the matching HLS variant or source
  /// quality by label, falling back to the current default when absent.
  void _applyDefaultQuality() {
    // Per-title remembered quality wins over the global default.
    final url = showUrl;
    final pref =
        (url != null && url.isNotEmpty
            ? sl<TitlePrefsStore>().quality(sourceId, url)
            : null) ??
        sl<PlaybackPrefs>().defaultQuality;
    if (pref == 'auto') return;

    final variants = state.qualities; // already sorted high→low
    final srcQualities = sourceQualities; // already sorted high→low

    if (pref == 'highest') {
      if (variants.isNotEmpty) {
        selectQuality(variants.first);
      } else if (srcQualities.isNotEmpty) {
        selectSourceQuality(srcQualities.first);
      }
      return;
    }

    // Exact resolution match: an HLS variant by label, else a source quality.
    for (final v in variants) {
      if (v.quality == pref) {
        selectQuality(v);
        return;
      }
    }
    if (srcQualities.contains(pref)) {
      selectSourceQuality(pref);
      return;
    }

    // Fallback: the preferred resolution isn't offered → pick the NEAREST
    // available (e.g. 1080p wanted but only 4K/720p → closest, higher on a tie),
    // instead of silently leaving it on the adaptive default.
    final wanted = _resPx(pref);
    if (wanted == null) return;
    final nearVar = _nearestByRes(variants, (v) => v.quality, wanted);
    if (nearVar != null) {
      selectQuality(nearVar);
      return;
    }
    final nearSrc = _nearestByRes(srcQualities, (q) => q, wanted);
    if (nearSrc != null) selectSourceQuality(nearSrc);
  }

  /// Approximate vertical resolution (px) parsed from a quality label, for the
  /// nearest-available fallback. Handles 4K/2K/FHD/HD shorthand + bare numbers.
  static int? _resPx(String label) {
    final l = label.toLowerCase();
    if (l.contains('2160') || l.contains('4k') || l.contains('uhd')) return 2160;
    if (l.contains('1440') || l.contains('2k')) return 1440;
    if (l.contains('1080') || l.contains('fhd')) return 1080;
    if (l.contains('720')) return 720;
    if (l.contains('480')) return 480;
    if (l.contains('360')) return 360;
    if (l.contains('240')) return 240;
    final m = RegExp(r'(\d{3,4})').firstMatch(l);
    return m != null ? int.tryParse(m.group(1)!) : null;
  }

  /// The item whose label-resolution is closest to [wanted]. Inputs are sorted
  /// high→low, so a strict `<` keeps the HIGHER option on a tie.
  static T? _nearestByRes<T>(
    List<T> items,
    String? Function(T) labelOf,
    int wanted,
  ) {
    T? best;
    var bestDiff = 1 << 30;
    for (final it in items) {
      final px = _resPx(labelOf(it) ?? '');
      if (px == null) continue;
      final d = (px - wanted).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = it;
      }
    }
    return best;
  }

  /// Switch to a specific source (sub/dub or quality change), preserving position.
  Future<void> switchSource(VideoSource s) => _open(s, seekTo: _lastPos);

  /// User explicitly picked a source from the Sources sheet — remember it for
  /// this title (by label) so the same one is preferred next time, then switch.
  Future<void> selectSource(VideoSource s) async {
    final url = showUrl;
    final label = s.label?.trim();
    if (url != null && url.isNotEmpty && label != null && label.isNotEmpty) {
      await sl<TitlePrefsStore>().setSourceLabel(sourceId, url, label);
    }
    await switchSource(s);
  }

  // Language tokens used to re-match a remembered source across re-resolves
  // (URLs/sizes change, but the language usually persists in the label).
  static const List<String> _langTokens = [
    'hindi', 'english', 'tamil', 'telugu', 'malayalam', 'kannada', 'bengali',
    'marathi', 'punjabi', 'japanese', 'korean', 'dual', 'multi', 'org',
  ];

  static String? _langOf(String label) {
    final l = label.toLowerCase();
    for (final t in _langTokens) {
      if (l.contains(t)) return t;
    }
    return null;
  }

  /// The resolved source matching the title's remembered pick: exact label
  /// first, else same language token. Null when nothing was remembered/matched.
  VideoSource? _preferredSource(List<VideoSource> sources) {
    final url = showUrl;
    if (url == null) return null;
    final saved = sl<TitlePrefsStore>().sourceLabel(sourceId, url);
    if (saved == null) return null;
    for (final s in sources) {
      if ((s.label ?? '').trim() == saved) return s; // exact
    }
    final lang = _langOf(saved);
    if (lang != null) {
      for (final s in sources) {
        if (_langOf(s.label ?? '') == lang) return s; // same language
      }
    }
    return null;
  }

  /// Builds the quality menu from the first HLS master among `state.sources`
  /// (independent of which source plays by default). Fire-and-forget; the menu
  /// appears once the master is fetched + parsed. Resets prior quality state.
  void _buildQualityMenu(int gen) {
    emit(state.copyWith(qualities: const [], activeQuality: () => null));
    _hlsMaster = null;
    VideoSource? master;
    for (final s in state.sources) {
      if (s.container == SourceContainer.hls) {
        master = s;
        break;
      }
    }
    if (master == null) return;
    _hlsMaster = master;
    final m = master;
    fetchHlsVariants(m.url, m.headers, _dio).then((vs) {
      if (gen == _gen && vs.length > 1) {
        emit(state.copyWith(qualities: vs));
        // Variants arrive async (after the initial open), so re-apply the
        // default-quality pref now that the HLS ladder is known.
        _applyDefaultQuality();
      }
    });
  }

  /// Switch the HLS resolution. [v] == null → Auto (highest); otherwise the
  /// chosen variant. Keeps the MASTER playlist open and pins the rung via mpv's
  /// `hls-bitrate` rather than opening the bare variant URL — some masters
  /// (e.g. AnimeSalt) carry audio in separate renditions, so a bare video
  /// variant would play silently. Resumes at the live position.
  Future<void> selectQuality(HlsVariant? v) async {
    final master = _hlsMaster;
    if (master == null) return;
    // Target the variant by bitrate; 'max' for Auto (or when BANDWIDTH is
    // missing, since we can't pin precisely without it).
    final target = (v == null || v.bandwidth <= 0) ? 'max' : '${v.bandwidth}';
    final p = player.platform;
    if (p is NativePlayer) {
      try {
        await p.setProperty('hls-bitrate', target);
      } catch (_) {}
    }
    await _open(
      VideoSource(
        url: master.url, // always the master — preserves the audio renditions
        quality: v?.quality ?? 'auto',
        container: SourceContainer.hls,
        headers: master.headers,
        kind: master.kind,
        audioLang: master.audioLang,
        subtitles: master.subtitles,
      ),
      seekTo: _lastPos,
    );
    emit(state.copyWith(activeQuality: () => v));
  }

  /// Persist a manual quality pick — per-title (this movie/series) AND globally
  /// (so new titles start at the same preference). Best-effort.
  void _rememberQuality(String label) {
    final url = showUrl;
    if (url != null && url.isNotEmpty) {
      sl<TitlePrefsStore>().setQuality(sourceId, url, label);
    }
    sl<PlaybackPrefs>().setDefaultQuality(label);
  }

  /// User explicitly chose an HLS variant in the Quality sheet (null = Auto):
  /// remember it, then apply. (Programmatic [selectQuality] does NOT persist, so
  /// applying a 'highest'/fallback pick can't overwrite the user's stored label.)
  Future<void> chooseQuality(HlsVariant? v) async {
    _rememberQuality(v?.quality ?? 'auto');
    await selectQuality(v);
  }

  /// User explicitly chose a per-source quality label: remember it, then apply.
  Future<void> chooseSourceQuality(String q) async {
    _rememberQuality(q);
    await selectSourceQuality(q);
  }

  // ── Source-based quality (when there's no multi-variant HLS master) ───────
  // AllAnime etc. return several distinct sources that each carry a resolution
  // label but no HLS master playlist, so [qualities] is empty. Surface those
  // per-source qualities as selectable options instead.

  /// Distinct non-empty quality labels among the resolved sources for the
  /// active audio kind, high→low.
  List<String> get sourceQualities {
    final kind = state.active?.kind;
    final seen = <String>{};
    final out = <String>[];
    for (final s in sortByQuality(state.sources)) {
      if (kind != null && s.kind != kind) continue;
      final q = (s.quality ?? '').trim();
      if (q.isEmpty || seen.contains(q)) continue;
      seen.add(q);
      out.add(q);
    }
    return out;
  }

  /// The quality label of the currently-playing source (for the active check).
  String? get activeSourceQuality =>
      (state.active?.quality ?? '').trim().isEmpty
      ? null
      : state.active!.quality!.trim();

  /// Switch to the best source matching quality label [q] (same audio kind),
  /// preserving the live position.
  Future<void> selectSourceQuality(String q) async {
    final kind = state.active?.kind;
    for (final s in sortByQuality(state.sources)) {
      if ((s.quality ?? '').trim() == q && (kind == null || s.kind == kind)) {
        await switchSource(s);
        return;
      }
    }
  }

  // Active torrent stream (Phase 1: one at a time). Null for normal playback.
  String? _activeTorrentId;
  StreamSubscription<TorrentProgress>? _torrentSub;

  /// Streams a torrent [s] into a local http url, driving [PlayerState.torrentPhase]
  /// as a buffering overlay. Returns a playable local-url source, or null if it
  /// couldn't (a clean error is emitted, no throw). Stops any previous torrent.
  Future<VideoSource?> _resolveTorrent(VideoSource s, int g) async {
    await _stopTorrent();
    emit(state.copyWith(torrentPhase: () => 'Finding peers…', error: () => null));
    _torrentSub = sl<TorrentService>().events().listen((p) {
      if (g != _gen) return;
      final txt = switch (p.state) {
        TorrentState.finding => 'Finding peers…',
        TorrentState.buffering =>
          'Buffering ${(p.bufferPct * 100).clamp(0, 100).toStringAsFixed(0)}%'
              '${p.peers > 0 ? ' · ${p.peers} peers' : ''}',
        TorrentState.ready => 'Starting…',
        TorrentState.error => 'Finding peers…',
      };
      emit(state.copyWith(torrentPhase: () => txt));
    });
    try {
      final t = await sl<TorrentService>().startStream(
        s.url,
        allowMobileData: sl<TorrentPrefs>().allowMobileData,
      );
      await _torrentSub?.cancel();
      _torrentSub = null;
      if (g != _gen) {
        await _stopTorrent();
        return null;
      }
      _activeTorrentId = t.id;
      emit(state.copyWith(torrentPhase: () => null));
      // A local progressive stream — treat as a plain file (mp4 tuning, no
      // headers); keep the original quality/label/subs.
      return VideoSource(
        url: t.localUrl,
        quality: s.quality,
        label: s.label,
        container: SourceContainer.mp4,
        kind: s.kind,
        audioLang: s.audioLang,
        subtitles: s.subtitles,
      );
    } catch (e) {
      await _torrentSub?.cancel();
      _torrentSub = null;
      if (g != _gen) return null;
      final msg = (e is PlatformException && e.code == 'wifi_only')
          ? 'Torrents are set to Wi-Fi only. Turn on mobile data for torrents '
              'in Settings › Torrents.'
          : "Couldn't stream this torrent — no peers or it timed out. "
              'Try another source.';
      emit(state.copyWith(
        torrentPhase: () => null,
        loadingSources: false,
        error: () => msg,
      ));
      return null;
    }
  }

  /// Stops the active torrent (if any) and cleans up its listener.
  Future<void> _stopTorrent() async {
    final id = _activeTorrentId;
    _activeTorrentId = null;
    await _torrentSub?.cancel();
    _torrentSub = null;
    if (id != null) {
      try {
        await sl<TorrentService>().stop(id);
      } catch (_) {}
    }
  }

  Future<void> _open(
    VideoSource s, {
    Duration? seekTo,
    int? gen,
    // When set, mpv plays this URL instead of [s.url] while [s] stays the active
    // source (so the picker highlight is unchanged). Used to transparently swap
    // a Cloudflare-blocked Aniyomi stream onto its hidden proxy fallback.
    String? playUrlOverride,
  }) async {
    final g = gen ?? ++_gen;
    // Torrent sources stream through the native engine into a local http url,
    // which then opens exactly like any progressive file. This branch is the
    // ONLY torrent-specific code in the open path; direct urls skip it entirely.
    if (isTorrentUrl(s.url)) {
      final resolved = await _resolveTorrent(s, g);
      if (g != _gen || resolved == null) return; // superseded or failed (error emitted)
      s = resolved;
    }
    _startTimer?.cancel();
    _startedThisSource = false; // reset; set true once this source plays
    emit(state.copyWith(active: () => s, error: () => null));
    // When auto-resume is off, ignore the saved resume mark and start from the
    // explicit seek (a mid-session source/quality switch) or the very start.
    // In a Watch Together room the room position is authoritative, not the
    // user's personal mark.
    final autoResume = sl<PlaybackPrefs>().autoResume && roomRole == RoomRole.none;
    final mark =
        autoResume ? resume.get(sourceId, _showKey, currentEpisode.id) : null;
    var resumeAt =
        (mark != null && !mark.finished) ? mark.position : Duration.zero;
    // Fallback when the per-episode ResumeStore key didn't match (the provider
    // regenerated the episode's opaque data id between sessions): resume from
    // the position the Continue Watching entry itself recorded. First open only
    // — consume it so a later source/quality switch keeps the live position.
    if (autoResume && resumeAt <= Duration.zero && initialResume > Duration.zero) {
      resumeAt = initialResume;
    }
    initialResume = Duration.zero;
    // A fresh resume-open (no explicit seekTo) arms the pending-resume target so
    // a re-open that fires before we've reached it can't pull us back.
    if ((seekTo == null || seekTo <= Duration.zero) && resumeAt > Duration.zero) {
      _pendingResume = resumeAt;
    }
    // A source/quality switch passes seekTo: _lastPos to keep the position. But
    // right after a resume-open _lastPos is still ~0, so an early default-quality
    // switch would re-open near 0 and wipe the resume. Keep targeting the pending
    // resume until we've actually reached it; otherwise honor seekTo / the mark.
    final base = (seekTo != null && seekTo > Duration.zero) ? seekTo : resumeAt;
    final start = _pendingResume > base ? _pendingResume : base;
    // Ensure mpv tuning (incl. the HLS fake-extension relaxation) is applied
    // before opening — otherwise the first file opens without it (black screen
    // on AnimeSalt/AnimixStream-style streams).
    await _mpvConfigured;
    // HLS needs the fake-extension relaxation + per-segment reconnect
    // (http_persistent=0) for anti-leech CDNs. But forcing http_persistent=0 on
    // a progressive MP4 makes file-hosts throttle/drop it mid-stream (a fresh
    // TCP per read) — the "movie freezes in the middle" report. So apply that
    // string only to HLS; let MP4 use persistent connections (mpv's default).
    final plat = player.platform;
    if (plat is NativePlayer) {
      final isHls = s.container == SourceContainer.hls;
      await plat.setProperty(
        'demuxer-lavf-o',
        isHls
            ? 'extension_picky=0,allowed_extensions=ALL,http_persistent=0,'
                  'analyzeduration=2000000'
            : 'extension_picky=0,allowed_extensions=ALL,analyzeduration=2000000',
      );
      // Progressive MP4 file hosts often drop the connection right after a
      // range-request seek (resume / scrub), which stalls playback at the seek
      // point. Let libavformat reconnect and continue — what ExoPlayer (and so
      // CloudStream) does natively. HLS reconnects per-segment already.
      if (!isHls) {
        await plat.setProperty(
          'stream-lavf-o',
          'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,'
              'reconnect_delay_max=30',
        );
      }
      // Set mpv's `start` BEFORE loadfile so it opens AT the resume position (a
      // range request to that offset), the way CloudStream sets the start
      // position at prepare time. media_kit's own Media.start is applied late —
      // in its playlist-pos callback, AFTER the file already began decoding at
      // 0 — so slow remote MP4s (file hosts) ignore it and land back at 0. We
      // set it ourselves before open, and to '0' otherwise (the property is
      // sticky across files, so it must be reset every open).
      await plat.setProperty(
        'start',
        start > Duration.zero
            ? (start.inMilliseconds / 1000).toStringAsFixed(3)
            : '0',
      );
    }
    final playUrl = playUrlOverride ?? s.url;
    _isProxiedStream = playUrl.startsWith('http://127.0.0.1');
    // A direct Aniyomi stream can hang on Cloudflare without a clean mpv error —
    // arm a start watchdog to swap to its hidden proxy fallback if it never
    // starts. Aniyomi-only + direct-only, so other sources are untouched.
    _startTimer?.cancel();
    if (playUrlOverride == null &&
        sourceId.startsWith('ani:') &&
        !_isProxiedStream &&
        s.proxyUrl != null) {
      _startTimer = Timer(const Duration(seconds: 10), () {
        if (!_startedThisSource) {
          _open(s, seekTo: _lastPos, playUrlOverride: s.proxyUrl);
        }
      });
    }
    await player.open(
      Media(playUrl, httpHeaders: s.headers),
    );
    if (g != _gen) return; // superseded mid-open
    // Discord Rich Presence: announce the episode now playing.
    final discordTitle = showTitle ?? scrobbleTitle;
    if (discordTitle != null &&
        discordTitle.isNotEmpty &&
        sl.isRegistered<DiscordRpc>()) {
      sl<DiscordRpc>().setWatching(
        title: discordTitle,
        episodeLabel: 'Episode ${currentEpisode.number}',
        posterUrl: cover,
        startMs: DateTime.now().millisecondsSinceEpoch,
      );
    }
    // Some streams ignore Media.start (the seek-on-open doesn't take), so the
    // user lands back at 0. Verify a moment later and re-seek if needed.
    if (start > Duration.zero) {
      _verifyResume(start, g);
      _resumeWatchdog(g);
    }
    // Apply the preferred speed ONCE, now that a media is actually loaded
    // (setting it before any open doesn't stick). Mid-session overlay changes
    // are never clobbered afterwards.
    if (!_defaultRateApplied) {
      _defaultRateApplied = true;
      final url = showUrl;
      final perTitle = (url != null && url.isNotEmpty)
          ? sl<TitlePrefsStore>().speed(sourceId, url)
          : null;
      player.setRate(perTitle ?? sl<PlaybackPrefs>().defaultSpeed);
    }
    // Seed the source's default subtitle ONLY in Auto mode. With a specific
    // language / Off preference, _tryApplySubPref is the sole authority —
    // seeding a default here would race and CLOBBER the preferred pick (proven:
    // the seed's setSubtitleTrack lands after the preferred one and mpv shows
    // the seed). For Auto, the seed gives the user the source's default sub.
    if (s.subtitles.isNotEmpty &&
        sl<PlaybackPrefs>().subtitlePreference.isEmpty) {
      final sub = s.subtitles.firstWhere(
        (x) => x.isDefault,
        orElse: () => s.subtitles.first,
      );
      await player.setSubtitleTrack(
        SubtitleTrack.uri(
          sub.url,
          title: sub.label ?? sub.lang,
          language: sub.lang,
        ),
      );
    }
    _reapplySync(); // restore sub/audio delay (mpv clears it on a new file)
    applySubtitleStyle(); // restore subtitle size/colour/background
    _tryApplySubPref(); // apply the global subtitle preference (off / lang / auto)
  }

  /// Try the next source after the current one fails (dead/DRM/unsupported),
  /// preserving the live position and the audio kind.
  Future<void> _onPlaybackError(String e) async {
    debugPrint('[player] error: $e');
    // A torrent local stream buffers/blips while pieces download — that's normal,
    // not a dead source. Never fail over: it would restart the torrent from
    // scratch (re-fetch metadata, wipe the cache) and churn native SessionManagers
    // until the app force-closes. mpv recovers on its own once the pieces land.
    if (_activeTorrentId != null) return;
    final lower = e.toLowerCase();
    // libmpv emits many non-fatal warnings (e.g. the iOS Simulator has no
    // audio device). Only treat clear "this stream is unplayable" errors as a
    // reason to switch sources — never the audio-device/no-sound warnings.
    final fatal =
        lower.contains('failed to open') ||
        lower.contains('recognize file format') ||
        lower.contains('ffurl') ||
        lower.contains('connection');
    // If THIS source is already playing (position advanced), the error is a
    // transient/secondary one (HLS segment blip, failed sub track) — ignore it.
    // Only a source that NEVER started is worth cycling away from.
    if (_startedThisSource) return;
    if (!fatal || _recovering) return;
    // A direct Aniyomi stream that failed on Cloudflare → swap to its hidden
    // proxy fallback (same quality) rather than cycling through other qualities.
    final act = state.active;
    if (sourceId.startsWith('ani:') && !_isProxiedStream && act?.proxyUrl != null) {
      await _open(act!, seekTo: _lastPos, playUrlOverride: act.proxyUrl);
      return;
    }
    _recovering = true;
    final failed = state.active;
    if (failed != null) _tried.add(failed.url);
    // Never re-try a source we've already attempted this episode (prevents the
    // A→B→A thrash cascade).
    final remaining = state.sources
        .where((s) => !_tried.contains(s.url))
        .toList();
    final next = pickDefault(remaining, prefer: failed?.kind ?? AudioKind.sub);
    if (next != null) {
      await _open(next, seekTo: _lastPos);
      _applyDefaultQuality(); // honor the quality pref on the fallback source too
    } else {
      emit(
        state.copyWith(
          error: () =>
              'No source could be played on this device (tried ${_tried.length}).',
        ),
      );
    }
    _recovering = false;
  }

  /// A started source stalled for too long (dead host / pulled segment).
  /// Switch to the next untried mirror at the same position, transparently.
  Future<void> _failoverFromStall() async {
    // Bail if playback recovered (position moved past the stall anchor) or
    // we're no longer buffering — it was just a slow network dip, not a death.
    if (!player.state.buffering) return;
    if (_lastPos > _stallAnchorPos + const Duration(seconds: 1)) return;
    if (_recovering) return;
    _recovering = true;
    final dead = state.active;
    if (dead != null) _tried.add(dead.url);
    final remaining = state.sources
        .where((s) => !_tried.contains(s.url))
        .toList();
    final next = pickDefault(remaining, prefer: dead?.kind ?? AudioKind.sub);
    if (next != null) {
      _toast('Switching server…');
      await _open(next, seekTo: _lastPos);
      _applyDefaultQuality();
    } else {
      // Every mirror stalled — the cached resolution is likely dead/expired, so
      // drop it so the user's "retry" re-scrapes fresh links instead of replaying
      // the same stalled cache.
      sl<SourceRepository>().invalidateSources(
        _episodeUrl(currentEpisode),
        sourceId: sourceId,
      );
      emit(state.copyWith(error: () => 'All servers stalled — tap retry.'));
    }
    _recovering = false;
  }

  /// Re-seek shortly after open if the stream ignored Media.start (position is
  /// still near 0 instead of the resume target). Retries a couple of times to
  /// catch slow-loading sources.
  /// Heal a corrupted/unreachable resume mark: if a resume-open never produces
  /// real playback (position stuck near 0 well after open — e.g. the mark points
  /// past a stalling deep-seek), abandon the resume, restart from 0, and reset
  /// the bad mark so the title plays instead of freezing forever.
  Future<void> _resumeWatchdog(int g) async {
    await Future.delayed(const Duration(seconds: 15));
    if (g != _gen) return;
    final before = _lastPos;
    await Future.delayed(const Duration(seconds: 4));
    if (g != _gen) return;
    // Position hasn't advanced in 4s → playback is frozen (the resume seek
    // stalled on a deep / corrupted-mark target the host can't serve). Abandon
    // the resume, restart from 0, and reset the bad mark so the title plays.
    if ((_lastPos - before).abs() < const Duration(milliseconds: 600)) {
      _pendingResume = Duration.zero;
      await player.seek(Duration.zero);
      await resume.save(
        sourceId,
        _showKey,
        currentEpisode.id,
        Duration.zero,
        _lastDur,
      );
    }
  }

  Future<void> _verifyResume(Duration target, int g) async {
    // A seek issued while the stream is still buffering at position 0 is
    // silently dropped, so a fixed 3-try window often expires before slow
    // sources (remote MP4s) start producing frames — and the user lands at 0.
    // Poll for up to ~12s and only seek ONCE the player is actually playing
    // (a real position or a known duration), retrying until it sticks.
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future.delayed(const Duration(milliseconds: 750));
      if (g != _gen) return; // a newer open superseded this
      final pos = player.state.position;
      if ((pos - target).abs() <= const Duration(seconds: 8)) return; // reached
      // Seeking needs a KNOWN duration: remote MP4s (file hosts) report
      // duration only after mpv reads the moov atom, and a seek issued before
      // then is clamped to 0 — the "always starts from 0" bug. Wait for it.
      final dur = player.state.duration;
      if (dur > Duration.zero && target < dur) await player.seek(target);
    }
  }

  Future<void> playNext() async {
    if (state.currentIndex + 1 < episodes.length) {
      await openEpisode(state.currentIndex + 1);
    }
  }

  Future<void> playPrevious() async {
    if (state.currentIndex > 0) {
      await openEpisode(state.currentIndex - 1);
    }
  }

  // ── Accurate skip times (AniSkip, anime only) ─────────────────────────────
  List<SkipInterval> _skips = const [];
  int _skipsForIndex = -1;
  // Next-episode prefetch fires once per current episode, near the end, so the
  // following episode's stream is already resolved when binge-advancing. Tracks
  // the index it fired for so it re-arms whenever the episode/index changes.
  int _prefetchedNextForIndex = -1;
  List<SkipInterval> get currentSkips => _skips;

  Future<void> _fetchSkips(int index, Duration dur) async {
    _skips = const [];
    final ep = episodes[index];
    final num = ep.number?.toInt();
    final title = showTitle;
    if (num == null || title == null || title.isEmpty) return;
    try {
      final s = await sl<SkipService>()
          .skipTimes(title: title, episode: num, duration: dur);
      if (index == state.currentIndex) _skips = s; // ignore if switched away
    } catch (_) {}
  }

  // ── Subtitle / audio sync (delay offsets, applied via mpv) ────────────────
  Duration subtitleDelay = Duration.zero;
  Duration audioDelay = Duration.zero;

  // Aniyomi-style two-tap subtitle sync. Kept on the controller (not the sheet)
  // so a capture survives closing the sheet — the user taps "Voice heard", shuts
  // the sheet to watch, then reopens to tap "Subtitle seen". Playback position
  // (ms) at each tap; the applied delay adjustment is voice − text.
  int? subSyncVoiceMs;
  int? subSyncTextMs;

  /// Record a sync tap at the current playback position. When both points are
  /// set, folds `voice − text` into [subtitleDelay] and returns that delta (ms);
  /// otherwise returns null (one point captured, waiting for the other).
  int? captureSubSync(bool voice) {
    final pos = player.state.position.inMilliseconds;
    if (voice) {
      subSyncVoiceMs = pos;
    } else {
      subSyncTextMs = pos;
    }
    if (subSyncVoiceMs != null && subSyncTextMs != null) {
      final delta = subSyncVoiceMs! - subSyncTextMs!;
      subSyncVoiceMs = null;
      subSyncTextMs = null;
      final ms = (subtitleDelay.inMilliseconds + delta).clamp(-30000, 30000);
      setSubtitleDelay(Duration(milliseconds: ms));
      return delta;
    }
    return null;
  }

  /// Discard a pending sync capture (Clear/cancel).
  void clearSubSync() {
    subSyncVoiceMs = null;
    subSyncTextMs = null;
  }

  Future<void> setSubtitleDelay(Duration d) async {
    subtitleDelay = d;
    final p = player.platform;
    if (p is NativePlayer) {
      try {
        await p.setProperty('sub-delay', (d.inMilliseconds / 1000).toString());
      } catch (_) {}
    }
  }

  Future<void> setAudioDelay(Duration d) async {
    audioDelay = d;
    final p = player.platform;
    if (p is NativePlayer) {
      try {
        await p.setProperty('audio-delay', (d.inMilliseconds / 1000).toString());
      } catch (_) {}
    }
  }

  /// Re-apply the current sync offsets (mpv resets them on a new file).
  Future<void> _reapplySync() async {
    if (subtitleDelay != Duration.zero) await setSubtitleDelay(subtitleDelay);
    if (audioDelay != Duration.zero) await setAudioDelay(audioDelay);
  }

  /// Apply the saved subtitle styling (size / font / colour / background /
  /// position) via mpv. Called after each open and whenever the user changes a
  /// style preference.
  Future<void> applySubtitleStyle() async {
    final p = player.platform;
    if (p is! NativePlayer) return;
    final prefs = sl<PlaybackPrefs>();
    // Text colour: prefer the new hex pref (#RRGGBBAA → mpv #AARRGGBB), else
    // fall back to the legacy white/yellow token.
    final color =
        _mpvColor(prefs.subtitleColorHex) ??
        (prefs.subtitleColor == 'yellow' ? '#FFFFFF00' : '#FFFFFFFF');
    // Box behind subtitles: prefer the new opacity slider (0–1 → alpha over
    // black), else the legacy on/off toggle. mpv colour is #AARRGGBB.
    final bgOpacity = prefs.subtitleBgOpacity;
    final back = bgOpacity > 0
        ? '#${_alphaHex(bgOpacity)}000000'
        : (prefs.subtitleBackground ? '#A0000000' : '#00000000');
    // Each property is set independently so a single rejected value can't abort
    // the rest (the old single try/catch did).
    Future<void> set(String k, String v) async {
      try {
        await p.setProperty(k, v);
      } catch (_) {}
    }

    // CRITICAL: ASS/SSA subtitles (common for anime/scraped sources) carry their
    // OWN embedded styling, so mpv ignores sub-color/sub-font/sub-scale/sub-pos
    // by default → "changing the style does nothing". 'force' makes our settings
    // win for both ASS and plain (srt/vtt) subtitles.
    await set('sub-ass-override', 'force');
    await set('sub-scale', prefs.subtitleScale.toString());
    if (prefs.subtitleFont.isNotEmpty) {
      await set('sub-font', prefs.subtitleFont);
    }
    await set('sub-color', color);
    await set('sub-back-color', back);
    // A thin border keeps text legible without a box; mpv default is ~3.
    await set('sub-border-size', '3');
    await set('sub-pos', prefs.subtitlePosition.toString());
    // media_kit renders text subtitles via a Flutter overlay (not libass), so
    // the above mpv props are ignored in practice — the real styling is the
    // Video's SubtitleViewConfiguration. Bump so the player screen rebuilds it.
    subtitleStyleRev.value++;
  }

  /// Convert a `#RRGGBBAA` (or `#RRGGBB`) hex string into mpv's alpha-first
  /// `#AARRGGBB` form. Returns null on a malformed/empty value so the caller
  /// can fall back to the legacy token.
  static String? _mpvColor(String hex) {
    final h = hex.replaceFirst('#', '').trim();
    if (h.length == 6) return '#FF${h.toUpperCase()}';
    if (h.length == 8) {
      final rgb = h.substring(0, 6);
      final a = h.substring(6, 8);
      return '#${a.toUpperCase()}${rgb.toUpperCase()}';
    }
    return null;
  }

  /// Two-digit hex (00–FF) for an opacity in 0–1, for mpv's alpha-first colour.
  static String _alphaHex(double opacity) {
    final v = (opacity.clamp(0.0, 1.0) * 255).round();
    return v.toRadixString(16).padLeft(2, '0').toUpperCase();
  }

  /// Set the in-app volume (0–200%) via mpv's own 'volume' property — this is
  /// independent of the Android system volume — and persist it as the default.
  Future<void> setVolumeBoost(int percent) async {
    await sl<PlaybackPrefs>().setVolumeBoost(percent.clamp(0, 200));
    await _applyAudioFilters();
  }

  /// The mpv audio-filter chain from prefs. `volume=N` is a SOFTWARE gain on the
  /// decoded audio (applied inside libmpv, before the output) — so a >100% boost
  /// is genuinely louder than the source, independent of the Android system
  /// volume. dynaudnorm runs first so the user's boost isn't normalized away.
  String _audioFilterChain() {
    final prefs = sl<PlaybackPrefs>();
    final parts = <String>[];
    if (prefs.audioNormalize) parts.add('dynaudnorm');
    if (prefs.volumeBoost != 100) {
      parts.add('volume=${(prefs.volumeBoost / 100).toStringAsFixed(2)}');
    }
    return parts.join(',');
  }

  Future<void> _applyAudioFilters() async {
    final p = player.platform;
    if (p is! NativePlayer) return;
    try {
      await p.setProperty('af', _audioFilterChain());
    } catch (_) {}
  }

  /// Toggle dynamic audio normalization (mpv 'dynaudnorm' filter) and persist.
  Future<void> toggleAudioNormalize() async {
    final prefs = sl<PlaybackPrefs>();
    await prefs.setAudioNormalize(!prefs.audioNormalize);
    await _applyAudioFilters();
  }

  Future<void> _persist({bool flush = false}) async {
    // Nothing watched yet — don't overwrite a real mark with position 0.
    if (_lastPos <= Duration.zero) return;
    // Ignore a clearly bogus position (mpv occasionally emits a spurious huge
    // value mid-seek) — saving it corrupts the resume mark and can make a title
    // un-resumable (it then tries to seek past the end forever).
    if (_lastDur > Duration.zero &&
        _lastPos > _lastDur + const Duration(seconds: 5)) {
      return;
    }
    // While we're still trying to seek back to a resume point, don't let the low
    // positions we play through in the meantime clobber the saved mark.
    if (_pendingResume > Duration.zero &&
        _lastPos + const Duration(seconds: 3) < _pendingResume) {
      return;
    }
    // Glitch guard: during playback the position can't legitimately advance much
    // faster than wall-clock. A big forward jump that ISN'T a user seek is a
    // garbage value (broken-metadata remote MP4s emit these) — saving it would
    // corrupt the mark and stall every future resume. Reject it.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_goodPosMs > 0 && nowMs - _userSeekMs > 3000) {
      final elapsed = Duration(milliseconds: nowMs - _goodPosMs);
      final jump = _lastPos - _goodPos;
      if (jump > elapsed * 4 + const Duration(seconds: 10)) return; // implausible
    }
    _goodPos = _lastPos;
    _goodPosMs = nowMs;
    // Save resume even when the duration is unknown (downloaded HLS files):
    // ResumeMark.finished is false at duration 0, so resume still seeks back.
    await resume.save(sourceId, _showKey, currentEpisode.id, _lastPos, _lastDur);
    final h = history;
    final title = showTitle;
    if (h != null && title != null) {
      await h.save(
        HistoryEntry(
          sourceId: sourceId,
          showId: showUrl ?? sourceId,
          showTitle: title,
          cover: cover,
          coverHeaders: coverHeaders,
          showUrl: showUrl ?? '',
          category: _activeCategory,
          episodeId: currentEpisode.id,
          episodeNumber: currentEpisode.number,
          episodeUrl: currentEpisode.url,
          position: _lastPos,
          duration: _lastDur,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          malId: malId,
        ),
        flush: flush,
      );
    }
    _maybeScrobble();
  }

  /// AniList auto-scrobble: once the current episode crosses 92% (or the player
  /// signals completion via [force], covering HLS streams with no reported
  /// duration), push it once per episode per session (the service also de-dupes
  /// persistently). Identifies the anime by [malId] when present, else by
  /// [scrobbleTitle]. Whole-numbered episodes only.
  /// Mark the anime CURRENT on AniList the instant playback starts.
  void _markWatching() {
    if (malId == null &&
        (scrobbleTitle == null || scrobbleTitle!.isEmpty) &&
        tmdbId == null &&
        (imdbId == null || imdbId!.isEmpty)) {
      return;
    }
    if (!sl.isRegistered<TrackerHub>()) return;
    sl<TrackerHub>().markWatching(
      malId: malId,
      title: scrobbleTitle,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
    );
  }

  void _maybeScrobble({bool force = false}) {
    if (malId == null &&
        (scrobbleTitle == null || scrobbleTitle!.isEmpty) &&
        tmdbId == null &&
        (imdbId == null || imdbId!.isEmpty)) {
      return; // nothing to identify the title by
    }
    if (!force) {
      if (_lastDur <= Duration.zero) return; // can't gauge % without duration
      if (_lastPos.inMilliseconds < _lastDur.inMilliseconds * 0.92) return;
    }
    final idx = state.currentIndex;
    if (_scrobbled.contains(idx)) return;
    final ep = currentEpisode.number;
    if (ep == null || ep <= 0 || ep != ep.truncateToDouble()) return;
    if (!sl.isRegistered<TrackerHub>()) return;
    _scrobbled.add(idx);
    sl<TrackerHub>().scrobble(
      malId: malId,
      title: scrobbleTitle,
      tmdbId: tmdbId,
      tmdbIsTv: tmdbIsTv,
      imdbId: imdbId,
      episode: ep.toInt(),
    );
  }

  /// Client-mode: apply the host's state without re-broadcasting. Seeks only on
  /// meaningful drift (the controller already gates with needsCorrection).
  Future<void> applyRemote(
      {required bool playing, required Duration position, double? rate}) async {
    if ((_lastPos - position).abs() > const Duration(milliseconds: 2500)) {
      // Reuse the robust resume machinery so the seek lands on flaky hosts.
      _pendingResume = position;
      await player.seek(position);
    }
    if (rate != null && rate > 0) player.setRate(rate);
    if (playing && !player.state.playing) player.play();
    if (!playing && player.state.playing) player.pause();
  }

  @override
  Future<void> close() async {
    await _persist(flush: true);
    // Leaving the player → drop the "Watching" presence back to browsing.
    if (sl.isRegistered<DiscordRpc>()) {
      sl<DiscordRpc>().setBrowsing(title: showTitle, posterUrl: cover);
    }
    for (final s in _subs) {
      s.cancel();
    }
    _stallTimer?.cancel();
    _toastTimer?.cancel();
    // Stop any active torrent stream + delete its buffered pieces.
    await _stopTorrent();
    toast.dispose();
    subtitleStyleRev.dispose();
    await player.dispose();
    return super.close();
  }
}
