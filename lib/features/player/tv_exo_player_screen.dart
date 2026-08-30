import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/di/injector.dart';
import '../../core/discord/discord_presence.dart';
import '../../core/discord/discord_rpc.dart';
import '../../core/metadata/episode_metadata_service.dart';
import '../../core/models/episode.dart';
import '../../core/models/episode_title.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/filler_service.dart';
import '../../core/playback/hls.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/playback/skip_service.dart';
import '../../core/playback/source_selection.dart';
import '../../core/playback/subtitle_download_service.dart';
import '../../core/playback/subtitle_font_stage.dart';
import 'subtitle_font_service.dart';
import '../../core/playback/subtitle_language.dart';
import '../../core/playback/subtitle_search_service.dart';
import '../../core/playback/title_prefs.dart';
import '../../core/playback/tv_playback_helpers.dart';
import '../../core/playback/tv_track_helpers.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/torrent/torrent_prefs.dart';
import '../../core/torrent/torrent_service.dart';
import '../../core/torrent/torrent_util.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/tv/tv_episode_range_chips.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_keys.dart';
import '../../core/tv/tv_load_error_dialog.dart';
import '../../core/ui/badge.dart';
import '../../core/ui/subtitle_language_picker.dart';
import '../../l10n/l10n.dart';
import '../detail/episode_filter.dart';
import 'tv_exo_controller.dart';
import 'tv_track_menu.dart';

/// TV ExoPlayer player (SP1a core: play/pause, D-pad seek, resume, next/prev).
/// Constructor mirrors PlayerScreen so the SP1d router can swap it in unchanged.
/// Reached only behind the EXO_SPIKE dev flag until SP1d.
class TvExoPlayerScreen extends StatefulWidget {
  const TvExoPlayerScreen({
    super.key,
    required this.sourceId,
    required this.resume,
    required this.resolveSources,
    this.episodes = const [],
    this.startIndex = 0,
    this.showUrl,
    this.showTitle,
    this.cover,
    this.coverHeaders,
    this.category = 'sub',
    this.availableCategories = const [],
    this.malId,
    this.scrobbleTitle,
    this.tmdbId,
    this.tmdbIsTv = false,
    this.imdbId,
  });

  final String sourceId;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;
  final List<Episode> episodes;
  final int startIndex;
  final String? showUrl;
  final String? showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String category;

  /// Categories the show actually offers ('sub'/'dub'), from the detail's
  /// sub/dub counts. Drives the Version toggle even when the current stream
  /// pool only resolved one kind (separate sub/dub episode lists).
  final List<String> availableCategories;
  final int? malId;
  final String? scrobbleTitle;
  final int? tmdbId;
  final bool tmdbIsTv;
  final String? imdbId;

  @override
  State<TvExoPlayerScreen> createState() => _TvExoPlayerScreenState();
}

class _TvExoPlayerScreenState extends State<TvExoPlayerScreen> {
  TvExoController? _c;
  // Mutable so a Sub/Dub switch can swap in the other category's episode list
  // (providers that ship separate lists per language). Seeded from the widget.
  late List<Episode> _episodes;
  int _index = 0;
  bool _episodesEnriched = false;
  bool _resumeSeeked = false;
  String? _error;
  int _lastSavedMs = 0;
  int _discordLastPos = 0;
  Timer? _discordPauseTimer;
  bool _discordPaused = false;

  final _dio = Dio();
  late String _category;
  List<VideoSource> _sources = const [];
  VideoSource? _activeSource;
  List<HlsVariant> _qualities = const [];
  HlsVariant? _activeQuality; // null = Auto
  int? _seekTargetMs; // one-shot seek on next ready (resume OR source switch)
  bool _menuOpen = false;
  /// Drill-in stack for the Settings side panel. Empty = root "Settings" page.
  final List<_TvSettingsPage> _menuStack = [];
  /// When true, the right-side panel is the Speed picker (opened from speed pill).
  bool _speedMenuOpen = false;
  double _speed = 1.0;
  // Focus for the player root (D-pad controls) and the up-next card. Overlays
  // (menu / search / up-next) must explicitly grab focus and hand it back here,
  // because the root Focus holds focus and `autofocus` can't steal it.
  final _rootFocus = FocusNode(debugLabel: 'tvExoRoot');
  final _upNextFocus = FocusNode(debugLabel: 'tvExoUpNext');
  Timer? _menuHideTimer; // auto-hide the track menu after inactivity

  // Netflix-style focusable control row (Episodes / Audio & Subs / Next). Nodes
  // are persisted so ◀▶ moves deterministically and ▼ can drop focus into the
  // row from the root; while a row button holds focus the 5s auto-hide is
  // paused so the buttons can't vanish under the user.
  final List<FocusNode> _rowFocusNodes = List.generate(
    3,
    (i) => FocusNode(debugLabel: 'tvExoRow$i'),
  );
  bool _controlRowFocused = false;
  bool _episodesOpen = false; // the episode-picker overlay
  int _episodeRangeIndex = 0; // 50-ep chunk in the picker
  // Its own scope so the picker can grab D-pad focus off the root (the root
  // holds focus and a child's autofocus can't steal it — same reason the track
  // menu uses a scope).
  final _episodesScope = FocusScopeNode(debugLabel: 'tvExoEpisodes');
  final _selectedRangeFocus = FocusNode(debugLabel: 'tvExoSelectedRange');
  final _currentEpisodeFocus = FocusNode(debugLabel: 'tvExoCurrentEpisode');

  bool _subApplied = false; // one-shot preferred-language per (re)load
  bool _subDownloadTried = false; // one auto-download attempt per episode
  final _subDownloads = <TvSubtitleConfig>[]; // sourced-in during playback
  String? _stagedFontPath;
  String _stagedFontFamily = '';
  List<SubtitleSearchResult>? _searchResults;

  List<SkipInterval> _skips = const [];
  bool _skipsFetched = false;
  /// Interval starts (ms) already auto-skipped for the current episode.
  final Set<int> _autoSkipped = <int>{};

  bool _markedWatching = false;
  final _scrobbled = <int>{}; // episode indices already scrobbled this session

  String? _torrentId;
  String? _torrentPhase; // non-null while a torrent is resolving
  int _loadGen = 0; // bumped per _open; guards stale async torrent resolves
  int? _upNextCountdown;
  Timer? _upNextTimer;
  bool _controlsVisible = true; // bottom controls; auto-hide after inactivity
  Timer? _controlsHideTimer;
  /// Touch-dragging the seek slider — keep chrome up and drive the thumb locally.
  bool _scrubbing = false;
  int? _scrubMs;
  bool _holdingSpeed = false; // D-pad RIGHT held → temporary 2× (YouTube-style)

  /// Filler episode NUMBERS from Jikan (same as phone player). Empty until
  /// fetched / for non-anime. Drives auto-skip and FILLER badges.
  final ValueNotifier<Set<int>> _fillerEps = ValueNotifier(const {});

  // One remote Back press can arrive TWICE: the overlay's key handler closes
  // it on key-DOWN, then the press still falls through as a route pop, whose
  // ladder — seeing the overlay already closed — would eat the NEXT rung and
  // hide the controls too (menu closes AND controls vanish in one press; with
  // video black that reads as "the app went blank"). Stamp overlay closes and
  // ignore the controls-hide rung briefly after one.
  int _lastOverlayCloseMs = 0;

  /// Whether the current Back press already did its one action on key-DOWN
  /// (hide controls / overlay just closed). When false, the press's key-UP
  /// performs the exit pop — see the goBack rung in [_onKey].
  bool _backPressConsumed = true;

  void _stampOverlayClose() =>
      _lastOverlayCloseMs = DateTime.now().millisecondsSinceEpoch;

  bool get _justClosedOverlay =>
      DateTime.now().millisecondsSinceEpoch - _lastOverlayCloseMs < 400;

  @override
  void initState() {
    super.initState();
    _episodes = widget.episodes;
    _index = _episodes.isEmpty
        ? 0
        : widget.startIndex.clamp(0, _episodes.length - 1);
    _category = widget.category;
    // Keep the screen awake during playback (mirrors the phone player) so TV
    // devices don't drop into a screensaver/daydream mid-episode. Gated by the
    // same user pref; released in dispose().
    if (sl<PlaybackPrefs>().keepScreenOn) WakelockPlus.enable();
    _ensureFiller();
  }

  void _ensureFiller() {
    final id = widget.malId;
    if (id == null) return;
    FillerService.instance.fillerEpisodes(id).then((s) {
      if (mounted) _fillerEps.value = s;
    });
  }

  /// Index the up-next / autoplay path will open (honours auto-skip filler).
  int? get _autoNextIndex => nextAutoplayIndex(
        currentIndex: _index,
        episodes: _episodes,
        fillerEps: _fillerEps.value,
        autoSkipFiller: sl<PlaybackPrefs>().autoSkipFiller,
      );

  Episode? get _ep => _episodes.isEmpty ? null : _episodes[_index];

  String get _resumeShowId => widget.showUrl ?? widget.sourceId;

  void _onViewCreated(int id) {
    final c = TvExoController(id);
    _c = c;
    c.duration.addListener(_maybeResumeSeek);
    c.position.addListener(_maybeSaveProgress);
    c.ended.addListener(_onEnded);
    c.audioTracks.addListener(_onTracksChanged);
    c.textTracks.addListener(_onTracksChanged);
    c.duration.addListener(_maybeFetchSkips);
    c.position.addListener(_scrobbleTick);
    c.position.addListener(_maybeAutoSkip);
    c.playing.addListener(_onPlayingChanged);
    c.duration.addListener(_pushDiscordWatchingIfDurationKnown);
    c.position.addListener(_maybeDiscordSeek);
    _bumpControls();
    _loadEpisode();
  }

  void _scrobbleTick() => _maybeScrobble();

  /// Show the bottom controls and (re)start the 5s inactivity hide. While
  /// playing, they fade out after 5s of no input; while paused they stay.
  void _bumpControls() {
    _controlsHideTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _controlsHideTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (_c?.playing.value == true &&
          !_menuOpen &&
          !_speedMenuOpen &&
          !_episodesOpen &&
          !_controlRowFocused &&
          !_scrubbing &&
          _searchResults == null &&
          _upNextCountdown == null) {
        setState(() {
          _controlsVisible = false;
          _speedMenuOpen = false;
        });
      }
    });
  }

  /// Touch on empty video/chrome:
  /// - side menu open → dismiss the menu
  /// - controls visible → play/pause (same as remote OK)
  /// - controls hidden → show controls
  void _toggleControlsFromTouch() {
    if (_menuOpen) {
      _closeMenu();
      return;
    }
    if (_speedMenuOpen) {
      _closeSpeedMenu();
      return;
    }
    if (_searchResults != null) {
      setState(() => _searchResults = null);
      _rootFocus.requestFocus();
      return;
    }
    if (_episodesOpen || _upNextCountdown != null) return;
    if (_controlsVisible) {
      _togglePlay();
    } else {
      _bumpControls();
    }
  }

  void _onPlayingChanged() {
    if (!mounted) return;
    if (_c?.playing.value == true) {
      _discordPaused = false;
      _discordPauseTimer?.cancel();
      _pushDiscordWatchingIfDurationKnown();
      _bumpControls(); // resumed → start the fade-out countdown
    } else {
      _controlsHideTimer?.cancel(); // paused → keep controls up
      if (!_controlsVisible) setState(() => _controlsVisible = true);
      _discordPauseTimer?.cancel();
      _discordPauseTimer = Timer(const Duration(milliseconds: 600), () {
        if (!mounted || _c?.playing.value == true) return;
        _discordPaused = true;
        _pushDiscordWatchingIfDurationKnown();
      });
    }
  }

  bool get _hasTitleId =>
      widget.malId != null ||
      widget.scrobbleTitle != null ||
      widget.tmdbId != null ||
      widget.imdbId != null;

  void _maybeMarkWatching() {
    if (_markedWatching || !_hasTitleId) return;
    _markedWatching = true;
    sl<TrackerHub>().markWatching(
      malId: widget.malId,
      title: widget.scrobbleTitle,
      tmdbId: widget.tmdbId,
      tmdbIsTv: widget.tmdbIsTv,
      imdbId: widget.imdbId,
    );
  }

  void _maybeScrobble({bool force = false}) {
    final c = _c;
    final ep = _ep;
    if (c == null || ep == null || !_hasTitleId) return;
    _maybeMarkWatching();
    final fire = force
        ? !_scrobbled.contains(_index)
        : shouldScrobble(
            positionMs: c.position.value,
            durationMs: c.duration.value,
            alreadyScrobbled: _scrobbled.contains(_index),
          );
    if (!fire) return;
    _scrobbled.add(_index);
    final epNum = (ep.number ?? (_index + 1)).toInt();
    sl<TrackerHub>().scrobble(
      malId: widget.malId,
      title: widget.scrobbleTitle,
      tmdbId: widget.tmdbId,
      tmdbIsTv: widget.tmdbIsTv,
      imdbId: widget.imdbId,
      episode: epNum,
    );
  }

  bool _loadErrorDialogOpen = false;

  Future<void> _ensureEpisodeMeta() async {
    if (_episodesEnriched) return;
    _episodesEnriched = true;
    final next = await _enrichList(_episodes);
    if (!mounted || identical(next, _episodes)) return;
    _episodes = next;
  }

  Future<List<Episode>> _enrichList(List<Episode> episodes) async {
    if (!sl.isRegistered<EpisodeMetadataService>()) return episodes;
    try {
      // _loadEpisode() waits on this before it starts playing, so cap it —
      // a cold cache on slow TV wifi shouldn't hold up the video. Timing out
      // lands in the catch below and we keep the source's own titles.
      return await sl<EpisodeMetadataService>()
          .enrich(
            episodes: episodes,
            type: widget.scrobbleTitle != null || widget.malId != null
                ? ProviderType.anime
                : ProviderType.movie,
            malId: widget.malId,
            tmdbId: widget.tmdbId,
            tmdbIsTv: widget.tmdbIsTv,
          )
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return episodes;
    }
  }

  Future<void> _loadEpisode() async {
    await _ensureEpisodeMeta();
    final ep = _ep;
    if (ep == null) {
      await _onEpisodeLoadFailed('No episode to play.');
      return;
    }
    _lastSavedMs = 0;
    try {
      final sources = await widget.resolveSources(
        tvEpisodeUrl(ep.url, _category),
      );
      final prefer = _category == 'dub' ? AudioKind.dub : AudioKind.sub;
      final src = pickDefault(sources, prefer: prefer);
      if (src == null) {
        await _onEpisodeLoadFailed('No playable source.');
        return;
      }
      _sources = sources;
      final mark = widget.resume.get(widget.sourceId, _resumeShowId, ep.id);
      await _open(src, seekToMs: mark?.position.inMilliseconds ?? 0);
    } catch (e) {
      await _onEpisodeLoadFailed('Could not load this episode.');
    }
  }

  Future<void> _onEpisodeLoadFailed(String message) async {
    if (!mounted) return;
    setState(() => _error = message);
    if (_loadErrorDialogOpen) return;
    _loadErrorDialogOpen = true;
    await showTvPlaybackLoadError(context);
    _loadErrorDialogOpen = false;
    if (!mounted) return;
    // First-open failure: leave the empty player so the user is back on
    // Detail. Keep this screen if a previous episode was already playing.
    if (_activeSource == null) Navigator.of(context).maybePop();
  }

  /// Loads [src] into the player (with any side-loaded subtitles) and arms a
  /// one-shot seek to [seekToMs] once a real duration arrives. [keepDownloads]
  /// preserves in-playback downloaded subs + the applied-pref flag (used when
  /// re-opening to attach a just-downloaded subtitle).
  Future<void> _open(
    VideoSource src, {
    int seekToMs = 0,
    bool keepDownloads = false,
  }) async {
    _activeSource = src;
    _c?.resetTimeline();
    _resumeSeeked = false;
    _seekTargetMs = seekToMs > 0 ? seekToMs : null;
    if (!keepDownloads) {
      _subApplied = false;
      _subDownloadTried = false;
      _subDownloads.clear();
      _skipsFetched = false;
      _skips = const [];
      _autoSkipped.clear(); // new episode → its OP/ED may auto-skip again
    }
    final gen = ++_loadGen; // this load supersedes any in-flight one
    _stopTorrent(); // kill any torrent from the previous source/episode
    _error = null;
    var playUrl = src.url;
    var playHeaders = src.headers ?? const <String, String>{};
    if (isTorrentUrl(src.url)) {
      final local = await _resolveTorrent(src.url, gen);
      // Bail if a newer _open superseded us while resolving, or on error/wifi
      // (shown by _resolveTorrent).
      if (local == null || gen != _loadGen || !mounted) return;
      playUrl = local;
      playHeaders = const {};
    }
    final subs = _subtitleConfigs(src);
    await _c?.setSource(
      playUrl,
      playHeaders,
      subtitles: subs,
      mimeType: _mimeForSource(src),
      // ClearKey DRM (null for every ordinary source → no clearkey session).
      drmKid: src.drmKid,
      drmKey: src.drmKey,
    );
    await _applyCaptionStyle();
    _applyPlaybackTuning();
    _loadQualities(src);
    // Discord Rich Presence: announce the episode now playing. This screen
    // hosts a native ExoPlayer PlatformView (not PlayerController), so the
    // phone player's setWatching never fired here — mirror it.
    _pushDiscordWatchingIfDurationKnown();
  }

  void _pushDiscordWatchingIfDurationKnown() {
    if ((_c?.duration.value ?? 0) <= 0) return;
    _pushDiscordWatching();
  }

  void _maybeDiscordSeek() {
    final c = _c;
    if (c == null) return;
    final p = c.position.value;
    if ((p - _discordLastPos).abs() > 3000) {
      _pushDiscordWatchingIfDurationKnown();
    }
    _discordLastPos = p;
  }

  void _pushDiscordWatching() {
    final title = widget.showTitle;
    final ep = _ep;
    final c = _c;
    if (ep == null ||
        title == null ||
        title.isEmpty ||
        !sl.isRegistered<DiscordRpc>()) {
      return;
    }
    unawaited(
      sl<DiscordRpc>().setWatching(
        title: title,
        episodeLabel: discordEpisodeLabel(ep, fallbackNumber: _index + 1),
        posterUrl: widget.cover,
        position: Duration(milliseconds: c?.position.value ?? 0),
        duration: Duration(milliseconds: c?.duration.value ?? 0),
        playing: !_discordPaused,
      ),
    );
  }

  /// Drop Watching when the player exits so the profile status actually
  /// disappears (the detail screen underneath will not re-fire browsing).
  void _announceBrowsing() {
    if (!sl.isRegistered<DiscordRpc>()) return;
    sl<DiscordRpc>().clear(delay: DiscordRpc.playerExitClearDelay);
  }

  Future<String?> _resolveTorrent(String uri, int gen) async {
    setState(() => _torrentPhase = 'Finding peers…');
    // Local subscription (not a shared field) so an overlapping _open can't
    // cancel this resolve's stream, or vice-versa. Stale ticks are ignored.
    final sub = sl<TorrentService>().events().listen((e) {
      if (!mounted || gen != _loadGen) return;
      if (e.state == TorrentState.buffering) {
        setState(
          () => _torrentPhase = 'Buffering ${(e.bufferPct * 100).round()}%',
        );
      } else if (e.state == TorrentState.finding) {
        setState(() => _torrentPhase = 'Finding peers…');
      }
    });
    try {
      final t = await sl<TorrentService>().startStream(
        uri,
        allowMobileData: sl<TorrentPrefs>().allowMobileData,
      );
      await sub.cancel();
      if (gen != _loadGen) {
        // A newer load superseded us — stop the torrent WE just started so it
        // doesn't leak, and let the caller bail.
        sl<TorrentService>().stop(t.id);
        return null;
      }
      _torrentId = t.id;
      if (mounted) setState(() => _torrentPhase = null);
      return t.localUrl;
    } on PlatformException catch (e) {
      await sub.cancel();
      if (gen != _loadGen) return null;
      if (mounted) {
        setState(() {
          _torrentPhase = null;
          _error = e.code == 'wifi_only'
              ? 'Connect to Wi-Fi or allow mobile data in Settings to stream torrents.'
              : 'Could not start the torrent.';
        });
      }
      return null;
    } catch (_) {
      await sub.cancel();
      if (gen != _loadGen) return null;
      if (mounted) {
        setState(() {
          _torrentPhase = null;
          _error = 'Could not start the torrent.';
        });
      }
      return null;
    }
  }

  void _stopTorrent() {
    final id = _torrentId;
    if (id != null) {
      sl<TorrentService>().stop(id);
      _torrentId = null;
    }
  }

  /// Explicit container MIME so ExoPlayer builds the correct MediaSource
  /// instead of guessing from a URL that may be tokenized (no file extension).
  /// HLS is hinted from the CloudStream `container` flag (set from isM3u8) or a
  /// `.m3u8` URL; DASH/MP4 only from an explicit extension. Null → let ExoPlayer
  /// infer (now that the DASH + SmoothStreaming modules are bundled). Torrent
  /// sources return null (their local stream URL is inferred).
  String? _mimeForSource(VideoSource src) {
    final u = src.url.toLowerCase();
    if (src.container == SourceContainer.hls || u.contains('.m3u8')) {
      return 'application/x-mpegURL';
    }
    if (u.contains('.mpd')) return 'application/dash+xml';
    if (u.contains('.mp4')) return 'video/mp4';
    return null;
  }

  void _applyPlaybackTuning() {
    _holdingSpeed = false; // a fresh load always starts at the chosen speed
    final perTitle = sl<TitlePrefsStore>().speed(
      widget.sourceId,
      _resumeShowId,
    );
    _speed = perTitle ?? sl<PlaybackPrefs>().defaultSpeed;
    _c?.setPlaybackSpeed(_speed);
    _c?.setVolumeBoost(sl<PlaybackPrefs>().volumeBoost);
  }

  List<TvSubtitleConfig> _subtitleConfigs(VideoSource src) => [
    for (final s in src.subtitles)
      TvSubtitleConfig(
        url: s.url,
        lang: s.lang,
        label: s.label,
        mime: subtitleMime(s.format, url: s.url),
      ),
    ..._subDownloads,
  ];

  void _maybeResumeSeek() {
    final c = _c;
    if (c == null || c.duration.value <= 0 || _resumeSeeked) return;
    final target = _seekTargetMs ?? 0;
    if (TvExoController.shouldResumeSeek(
      resumeMs: target,
      durationMs: c.duration.value,
      alreadySeeked: _resumeSeeked,
    )) {
      _resumeSeeked = true;
      c.seek(target);
    } else {
      _resumeSeeked = true; // nothing to seek; don't re-check every tick
    }
  }

  /// Opt-in auto-skip of the opening / ending, on every position tick. Waits for
  /// the resume seek to be settled — before that the player reports ~0, which
  /// sits inside the opening, and skipping there would strand a resumed episode
  /// at the end of its OP instead of where the user left off.
  void _maybeAutoSkip() {
    final c = _c;
    if (c == null || _skips.isEmpty || !_resumeSeeked) return;
    final prefs = sl<PlaybackPrefs>();
    final op = prefs.autoSkipOp;
    final ed = prefs.autoSkipEd;
    final recap = prefs.autoSkipRecap;
    if (!op && !ed && !recap) return;
    final iv = autoSkipAt(
      _skips,
      Duration(milliseconds: c.position.value),
      op: op,
      ed: ed,
      recap: recap,
      fired: _autoSkipped,
    );
    if (iv == null) return;
    _autoSkipped.add(iv.start.inMilliseconds);
    c.seek(iv.end.inMilliseconds);
  }

  void _maybeFetchSkips() {
    final c = _c;
    final ep = _ep;
    if (c == null || ep == null || _skipsFetched || c.duration.value <= 0) {
      return;
    }
    _skipsFetched = true;
    // Auto-skip needs the same timings the manual button does, so fetch when
    // either feature is on — not just the button.
    final prefs = sl<PlaybackPrefs>();
    if (!prefs.skipIntro &&
        !prefs.autoSkipOp &&
        !prefs.autoSkipEd &&
        !prefs.autoSkipRecap) {
      return;
    }
    final title = widget.showTitle;
    if (title == null || title.isEmpty) return;
    final epNum = (ep.number ?? (_index + 1)).toInt();
    sl<SkipService>()
        .skipTimes(
          title: title,
          episode: epNum,
          duration: Duration(milliseconds: c.duration.value),
        )
        .then((s) {
          if (mounted) setState(() => _skips = s);
        })
        .catchError((_) {});
  }

  Future<void> _loadQualities(VideoSource src) async {
    var qs = const <HlsVariant>[];
    // Same three rungs as the phone: the plugin's tag, then the url, then an
    // actual look. TV used to test the url only, so a tagged-HLS source whose
    // url hides the extension behind a token got no quality list here while
    // the phone found one — the two players disagreed on the same stream.
    final tagged = src.container == SourceContainer.hls;
    final byUrl = looksLikeHlsUrl(src.url);
    final torrent = src.container == SourceContainer.torrent;
    final drm = src.drmKid != null && src.drmKid!.isNotEmpty;
    if (!torrent && !drm) {
      try {
        qs = await fetchHlsVariants(
          src.url,
          src.headers ?? const {},
          _dio,
          sniff: !tagged && !byUrl,
        );
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _qualities = qs;
      _activeQuality = null; // Auto after a fresh load
      // Track ids index into the OLD stream's groups, so a stale pin would
      // tick the wrong row (or none) on the new one.
      _activeVideoTrackId = null;
    });
    // Apply the user's default-quality pref (HLS only).
    final v = decideDefaultQuality(
      variants: qs,
      pref: sl<PlaybackPrefs>().defaultQuality,
    );
    if (v != null) _selectQuality(v);
  }

  Future<void> _applyCaptionStyle() async {
    final p = sl<PlaybackPrefs>();
    final style = captionStyleFromPrefs(
      scale: p.subtitleScale,
      colorHex: p.subtitleColorHex,
      bgOpacity: p.subtitleBgOpacity,
      font: p.subtitleFont,
      outlineType: p.subtitleOutlineType,
    );
    final path = await _stageFont(style.fontFamily);
    _c?.applyCaptionStyle(
      style,
      fontPath: path,
      positionPref: p.subtitlePosition,
    );
  }

  /// Stages the chosen font once (shared with the native TV player) and
  /// caches the path so repeated style changes don't re-copy. Null for default.
  /// Download-on-demand families are fetched via [SubtitleFontService] first.
  Future<String?> _stageFont(String family) async {
    if (family.isEmpty) return null;
    if (family == _stagedFontFamily && _stagedFontPath != null) {
      return _stagedFontPath;
    }
    await SubtitleFontService.instance.ensure(family);
    final path = await stageSubtitleFont(family);
    if (path != null) {
      _stagedFontFamily = family;
      _stagedFontPath = path;
    }
    return path;
  }

  void _selectQuality(HlsVariant? v) {
    setState(() => _activeQuality = v);
    _c?.setMaxVideoBitrate(v?.bandwidth ?? 0);
  }

  /// Sources for the active sub/dub kind, or all sources when the content
  /// isn't kind-split (movies / unknown). Backs the Servers menu.
  List<VideoSource> _qualityPool() {
    final kind = _category == 'dub' ? AudioKind.dub : AudioKind.sub;
    final pool = sourcesForKind(_sources, kind);
    return pool.isNotEmpty ? pool : _sources;
  }

  /// Human label for a source mirror in the Servers menu — the provider's own
  /// label (with quality appended when not already present), else the quality,
  /// else the container name.
  String _serverLabel(VideoSource s) {
    final label = s.label;
    final q = s.quality;
    if (label != null && label.isNotEmpty) {
      return (q != null && q.isNotEmpty && !label.contains(q))
          ? '$label · $q'
          : label;
    }
    return (q != null && q.isNotEmpty) ? q : s.container.name;
  }

  /// The rendition the user pinned, or null while ExoPlayer is adapting freely.
  String? _activeVideoTrackId;

  void _selectVideoTrack(TvTrack? t) {
    setState(() => _activeVideoTrackId = t?.id);
    _c?.selectVideoTrack(t?.id);
  }

  void _selectAudio(TvTrack t) => _c?.selectAudioTrack(t.id);

  void _switchCategory(String cat) {
    if (cat == _category) return;
    // Re-resolve the current episode under the new category, keeping position.
    final pos = _c?.position.value ?? 0;
    () async {
      final ep = _ep;
      if (ep == null) return;
      try {
        // Two provider shapes: (1) the language is a URL segment (/sub/ ↔ /dub/)
        // — tvEpisodeUrl rewrites in place and the same list works; (2) separate
        // episode lists per language — the rewrite is a no-op, so re-fetch the
        // other list and swap it in (mirrors the phone's switchCategory).
        final rewritten = tvEpisodeUrl(ep.url, cat);
        var epUrl = rewritten;
        var newEpisodes = _episodes;
        var newIndex = _index;
        if (rewritten == ep.url && widget.showUrl != null) {
          final other = await sl<SourceRepository>().episodes(
            widget.showUrl!,
            category: cat,
            sourceId: widget.sourceId,
          );
          if (other.isNotEmpty) {
            newEpisodes = await _enrichList(other);
            newIndex = _index < other.length ? _index : 0;
            epUrl = other[newIndex].url;
          }
        }
        final sources = await widget.resolveSources(epUrl);
        final prefer = cat == 'dub' ? AudioKind.dub : AudioKind.sub;
        final src = pickDefault(sources, prefer: prefer);
        if (src == null) return;
        _sources = sources;
        _episodes = newEpisodes;
        _index = newIndex;
        _category = cat;
        // Remember the choice for this title so the next open honours it.
        if (widget.showUrl != null) {
          sl<TitlePrefsStore>().setCategory(
            widget.sourceId,
            widget.showUrl!,
            cat,
          );
        }
        await _open(src, seekToMs: pos);
        if (mounted) setState(() {});
      } catch (_) {}
    }();
  }

  List<TvMenuOption> _buildMenuOptions(TvExoController c) {
    final page =
        _menuStack.isEmpty ? _TvSettingsPage.root : _menuStack.last;
    switch (page) {
      case _TvSettingsPage.root:
        return _rootSettingsOptions(c);
      case _TvSettingsPage.servers:
        return _serversOptions(c);
      case _TvSettingsPage.quality:
        return _qualityOptions(c);
      case _TvSettingsPage.audio:
        return _audioOptions(c);
      case _TvSettingsPage.subs:
        return _subsOptions(c);
      case _TvSettingsPage.captionStyle:
        return _captionStyleOptions();
      case _TvSettingsPage.captionSize:
        return _captionSizeOptions();
      case _TvSettingsPage.captionColor:
        return _captionColorOptions();
      case _TvSettingsPage.captionEdge:
        return _captionEdgeOptions();
      case _TvSettingsPage.captionBg:
        return _captionBgOptions();
      case _TvSettingsPage.captionFont:
        return _captionFontOptions();
      case _TvSettingsPage.captionPos:
        return _captionPosOptions();
      case _TvSettingsPage.volume:
        return _volumeOptions();
    }
  }

  String get _menuTitle {
    if (_menuStack.isEmpty) return 'Settings';
    return switch (_menuStack.last) {
      _TvSettingsPage.root => 'Settings',
      _TvSettingsPage.servers => 'Servers',
      _TvSettingsPage.quality => 'Quality',
      _TvSettingsPage.audio => 'Audio',
      _TvSettingsPage.subs => 'Subtitles/CC',
      _TvSettingsPage.captionStyle => 'Captions Styling',
      _TvSettingsPage.captionSize => 'Font Size',
      _TvSettingsPage.captionColor => 'Text Color',
      _TvSettingsPage.captionEdge => 'Edge Style',
      _TvSettingsPage.captionBg => 'Background',
      _TvSettingsPage.captionFont => 'Font',
      _TvSettingsPage.captionPos => 'Position',
      _TvSettingsPage.volume => 'Volume',
    };
  }

  void _pushMenu(_TvSettingsPage page) {
    setState(() => _menuStack.add(page));
    _bumpMenuHide();
  }

  void _popOrCloseMenu() {
    if (_menuStack.isNotEmpty) {
      setState(() => _menuStack.removeLast());
      _bumpMenuHide();
    } else {
      _closeMenu();
    }
  }

  TvMenuOption _navRow(String label, {String? trailing, required VoidCallback onSelect}) =>
      TvMenuOption(
        label: label,
        trailing: trailing,
        showCheck: false,
        onSelect: onSelect,
      );

  List<TvMenuOption> _rootSettingsOptions(TvExoController c) {
    final options = <TvMenuOption>[];
    final servers = sortByQuality(_qualityPool());
    if (servers.length > 1) {
      final active = servers.where((s) => s.url == _activeSource?.url).firstOrNull;
      options.add(_navRow(
        'Servers',
        trailing: active != null ? _serverLabel(active) : null,
        onSelect: () => _pushMenu(_TvSettingsPage.servers),
      ));
    }

    final qTrailing = _qualityTrailing(c);
    if (qTrailing != null) {
      options.add(_navRow(
        'Quality',
        trailing: qTrailing,
        onSelect: () => _pushMenu(_TvSettingsPage.quality),
      ));
    }

    final audio = c.audioTracks.value;
    final audioLabel = _selectedTrackLabel(audio) ??
        (_category == 'dub' ? 'Dub' : 'Sub');
    options.add(_navRow(
      'Audio',
      trailing: audioLabel,
      onSelect: () => _pushMenu(_TvSettingsPage.audio),
    ));

    final text = c.textTracks.value;
    final selectedSub = _selectedTrackLabel(text);
    final subsOff = selectedSub == null;
    options.add(_navRow(
      'Subtitles/CC',
      trailing: subsOff ? 'Off' : selectedSub,
      onSelect: () => _pushMenu(_TvSettingsPage.subs),
    ));

    options.add(_navRow(
      'Captions Styling',
      onSelect: () => _pushMenu(_TvSettingsPage.captionStyle),
    ));

    final vol = sl<PlaybackPrefs>().volumeBoost;
    options.add(_navRow(
      'Volume',
      trailing: vol == 100 ? '100%' : '$vol%',
      onSelect: () => _pushMenu(_TvSettingsPage.volume),
    ));
    return options;
  }

  String? _qualityTrailing(TvExoController c) {
    if (_qualities.isNotEmpty) {
      return _activeQuality?.quality ?? 'Auto';
    }
    if (c.videoTracks.value.length > 1) {
      final tracks = c.videoTracks.value;
      final overridden = tracks.any((t) => t.id == _activeVideoTrackId);
      if (!overridden) return 'Auto';
      final t = tracks.where((t) => t.id == _activeVideoTrackId).firstOrNull;
      return t?.height != null ? '${t!.height}p' : 'Track';
    }
    return null;
  }

  String? _selectedTrackLabel(List<TvTrack> tracks) {
    for (final t in tracks) {
      if (t.selected) {
        return t.label ?? (t.language.isEmpty ? null : t.language);
      }
    }
    return null;
  }

  List<TvMenuOption> _serversOptions(TvExoController c) {
    final servers = sortByQuality(_qualityPool());
    return [
      for (final s in servers)
        TvMenuOption(
          label: _serverLabel(s),
          selected: s.url == _activeSource?.url,
          onSelect: () {
            _open(s, seekToMs: c.position.value);
            _popOrCloseMenu();
          },
        ),
    ];
  }

  List<TvMenuOption> _qualityOptions(TvExoController c) {
    final options = <TvMenuOption>[];
    if (_qualities.isNotEmpty) {
      options.add(TvMenuOption(
        label: context.l10n.auto,
        selected: _activeQuality == null,
        onSelect: () {
          _selectQuality(null);
          setState(() {});
        },
      ));
      for (final v in _qualities) {
        options.add(TvMenuOption(
          label: v.quality,
          selected: _activeQuality?.url == v.url,
          onSelect: () {
            _selectQuality(v);
            setState(() {});
          },
        ));
      }
    } else if (c.videoTracks.value.length > 1) {
      final tracks = c.videoTracks.value;
      final overridden = tracks.any((t) => t.id == _activeVideoTrackId);
      options.add(TvMenuOption(
        label: context.l10n.auto,
        selected: !overridden,
        onSelect: () {
          _selectVideoTrack(null);
          setState(() {});
        },
      ));
      for (final t in tracks) {
        options.add(TvMenuOption(
          label: '${t.height}p',
          selected: overridden && t.id == _activeVideoTrackId,
          onSelect: () {
            _selectVideoTrack(t);
            setState(() {});
          },
        ));
      }
    }
    return options;
  }

  List<TvMenuOption> _audioOptions(TvExoController c) {
    final options = <TvMenuOption>[];
    final kinds = availableKinds(_sources);
    final poolHasBoth =
        kinds.contains(AudioKind.sub) && kinds.contains(AudioKind.dub);
    final showHasBoth =
        widget.availableCategories.contains('sub') &&
        widget.availableCategories.contains('dub');
    if (poolHasBoth || showHasBoth) {
      options.add(TvMenuOption(
        label: context.l10n.sub,
        selected: _category == 'sub',
        onSelect: () => _switchCategory('sub'),
      ));
      options.add(TvMenuOption(
        label: context.l10n.dub,
        selected: _category == 'dub',
        onSelect: () => _switchCategory('dub'),
      ));
    }
    final audio = c.audioTracks.value;
    if (audio.isEmpty) {
      options.add(TvMenuOption(
        label: context.l10n.defaultLabel,
        selected: true,
        onSelect: () {},
      ));
    } else {
      for (final t in audio) {
        options.add(TvMenuOption(
          label: t.label ?? (t.language.isEmpty ? 'Track' : t.language),
          selected: t.selected,
          onSelect: () => _selectAudio(t),
        ));
      }
    }
    return options;
  }

  List<TvMenuOption> _subsOptions(TvExoController c) {
    final text = c.textTracks.value;
    return [
      TvMenuOption(
        label: context.l10n.off,
        selected: text.every((t) => !t.selected),
        onSelect: () => c.selectTextTrack(null),
      ),
      for (final t in text)
        TvMenuOption(
          label: t.label ?? (t.language.isEmpty ? 'Subtitle' : t.language),
          selected: t.selected,
          onSelect: () => c.selectTextTrack(t.id),
        ),
      TvMenuOption(
        label: context.l10n.preferredLanguage,
        showCheck: false,
        onSelect: _pickPreferredLanguage,
      ),
      TvMenuOption(
        label: context.l10n.searchOnline,
        showCheck: false,
        onSelect: _openSubtitleSearch,
      ),
    ];
  }

  List<TvMenuOption> _captionStyleOptions() {
    final p = sl<PlaybackPrefs>();
    return [
      _navRow(
        'Font Size',
        trailing: tvCaptionSizeLabel(p.subtitleScale),
        onSelect: () => _pushMenu(_TvSettingsPage.captionSize),
      ),
      _navRow(
        'Text Color',
        trailing: tvCaptionColorLabel(p.subtitleColorHex),
        onSelect: () => _pushMenu(_TvSettingsPage.captionColor),
      ),
      _navRow(
        'Edge Style',
        trailing: tvCaptionEdgeLabel(p.subtitleOutlineType),
        onSelect: () => _pushMenu(_TvSettingsPage.captionEdge),
      ),
      _navRow(
        'Background',
        trailing: tvCaptionBgLabel(p.subtitleBgOpacity),
        onSelect: () => _pushMenu(_TvSettingsPage.captionBg),
      ),
      _navRow(
        'Font',
        trailing: tvCaptionFontLabel(p.subtitleFont),
        onSelect: () => _pushMenu(_TvSettingsPage.captionFont),
      ),
      _navRow(
        'Position',
        trailing: tvCaptionPositionLabel(p.subtitlePosition),
        onSelect: () => _pushMenu(_TvSettingsPage.captionPos),
      ),
    ];
  }

  List<TvMenuOption> _captionSizeOptions() {
    final current = sl<PlaybackPrefs>().subtitleScale;
    return [
      for (final (label, scale) in kTvCaptionSizes)
        TvMenuOption(
          label: label,
          selected: tvCaptionSizeLabel(current) == label,
          onSelect: () => _setCaptionScale(scale),
        ),
    ];
  }

  List<TvMenuOption> _captionColorOptions() {
    final current = sl<PlaybackPrefs>().subtitleColorHex.toUpperCase();
    return [
      for (final (hex, label) in kTvCaptionColors)
        TvMenuOption(
          label: label,
          selected: current == hex,
          onSelect: () => _setCaptionColor(hex),
        ),
    ];
  }

  List<TvMenuOption> _captionEdgeOptions() {
    final current = tvEdgeTypeFromOutlinePref(
      sl<PlaybackPrefs>().subtitleOutlineType,
    );
    return [
      for (final (id, label, type) in kTvCaptionEdgeTypes)
        TvMenuOption(
          label: label,
          selected: current == type,
          onSelect: () => _setCaptionEdge(id),
        ),
    ];
  }

  List<TvMenuOption> _captionBgOptions() {
    final current = sl<PlaybackPrefs>().subtitleBgOpacity;
    return [
      for (final (label, opacity) in kTvCaptionBackgrounds)
        TvMenuOption(
          label: label,
          selected: tvCaptionBgLabel(current) == label,
          onSelect: () => _setCaptionBg(opacity),
        ),
    ];
  }

  List<TvMenuOption> _captionFontOptions() {
    final current = sl<PlaybackPrefs>().subtitleFont;
    return [
      for (final f in kBundledSubtitleFonts)
        TvMenuOption(
          label: tvCaptionFontLabel(f),
          selected: current == f,
          onSelect: () => _setCaptionFont(f),
        ),
    ];
  }

  List<TvMenuOption> _captionPosOptions() {
    final current = sl<PlaybackPrefs>().subtitlePosition;
    return [
      for (final (label, pos) in kTvCaptionPositions)
        TvMenuOption(
          label: label,
          selected: tvCaptionPositionLabel(current) == label,
          onSelect: () => _setCaptionPos(pos),
        ),
    ];
  }

  List<TvMenuOption> _volumeOptions() {
    const volSteps = [100, 125, 150, 175, 200];
    final vol = sl<PlaybackPrefs>().volumeBoost;
    return [
      for (final v in volSteps)
        TvMenuOption(
          label: v == 100 ? '100% (normal)' : '$v%',
          selected: vol == v,
          onSelect: () => _setVolume(v),
        ),
    ];
  }

  Future<void> _setCaptionScale(double scale) async {
    await sl<PlaybackPrefs>().setSubtitleScale(scale);
    await _applyCaptionStyle();
    if (mounted) setState(() {});
  }

  Future<void> _setCaptionColor(String hex) async {
    await sl<PlaybackPrefs>().setSubtitleColorHex(hex);
    await _applyCaptionStyle();
    if (mounted) setState(() {});
  }

  Future<void> _setCaptionEdge(String id) async {
    await sl<PlaybackPrefs>().setSubtitleOutlineType(id);
    await _applyCaptionStyle();
    if (mounted) setState(() {});
  }

  Future<void> _setCaptionBg(double opacity) async {
    await sl<PlaybackPrefs>().setSubtitleBgOpacity(opacity);
    await _applyCaptionStyle();
    if (mounted) setState(() {});
  }

  Future<void> _setCaptionFont(String font) async {
    await sl<PlaybackPrefs>().setSubtitleFont(font);
    await _applyCaptionStyle();
    if (mounted) setState(() {});
  }

  Future<void> _setCaptionPos(int pos) async {
    await sl<PlaybackPrefs>().setSubtitlePosition(pos);
    await _applyCaptionStyle();
    if (mounted) setState(() {});
  }

  void _setSpeed(double s) {
    setState(() {
      _speed = s;
      _speedMenuOpen = false;
    });
    _c?.setPlaybackSpeed(s);
    sl<TitlePrefsStore>().setSpeed(widget.sourceId, _resumeShowId, s);
    sl<PlaybackPrefs>().setDefaultSpeed(s);
    _rootFocus.requestFocus();
  }

  void _setVolume(int v) {
    sl<PlaybackPrefs>().setVolumeBoost(v);
    _c?.setVolumeBoost(v);
    if (mounted) setState(() {});
  }

  void _openSpeedMenu() {
    setState(() {
      _speedMenuOpen = true;
      _menuOpen = false;
      _menuStack.clear();
    });
    _bumpMenuHide();
  }

  void _closeSpeedMenu() {
    _menuHideTimer?.cancel();
    _stampOverlayClose();
    setState(() => _speedMenuOpen = false);
    _rootFocus.requestFocus();
  }

  Future<void> _pickPreferredLanguage() async {
    final picked = await showSubtitleLanguagePicker(
      context,
      sl<PlaybackPrefs>().subtitlePreference,
    );
    if (picked == null) return;
    await sl<PlaybackPrefs>().setSubtitlePreference(picked);
    _subApplied = false;
    await _maybeApplySubPref();
    if (mounted) setState(() {});
  }

  Future<void> _openSubtitleSearch() async {
    final query = widget.showTitle ?? '';
    if (sl<PlaybackPrefs>().subtitleApiKey.isEmpty) {
      _toast('Add an OpenSubtitles API key in Settings to search.');
      return;
    }
    // Search in the user's preferred subtitle language when they've set one
    // (subtitlePreference is '' for Auto or 'off'); fall back to English.
    final pref = sl<PlaybackPrefs>().subtitlePreference;
    final lang = (pref.isEmpty || pref == 'off') ? 'en' : pref;
    List<SubtitleSearchResult> results;
    try {
      results = await SubtitleSearchService().search(query, language: lang);
    } on SubtitleSearchException catch (e) {
      _toast(e.toString());
      return;
    } catch (_) {
      _toast('Subtitle search failed.');
      return;
    }
    if (!mounted) return;
    if (results.isEmpty) {
      _toast('No subtitles found.');
      return;
    }
    // Reuse the menu panel to present results. Close the track menu so there's
    // a single focused overlay (the results panel grabs focus on mount).
    _menuHideTimer?.cancel(); // menu is going away — don't let it re-close
    setState(() {
      _menuOpen = false;
      _searchResults = results;
    });
  }

  Future<void> _applySearchResult(SubtitleSearchResult r) async {
    setState(() => _searchResults = null);
    _rootFocus.requestFocus();
    try {
      final path = await SubtitleSearchService().download(r);
      final cfg = TvSubtitleConfig(
        url: path,
        lang: r.language,
        label: r.name,
        mime: subtitleMime(r.format, url: path),
      );
      _subDownloads.add(cfg);
      final src = _activeSource;
      if (src != null) {
        await _open(
          src,
          seekToMs: _c?.position.value ?? 0,
          keepDownloads: true,
        );
      }
    } catch (_) {
      _toast('Could not download subtitle.');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openMenu() {
    setState(() {
      _menuOpen = true;
      _menuStack.clear();
      _speedMenuOpen = false;
    });
    _bumpMenuHide();
  }

  /// (Re)start the menu inactivity timer — reset on every menu interaction so
  /// it only auto-closes when the user has stopped navigating it.
  void _bumpMenuHide() {
    _menuHideTimer?.cancel();
    _menuHideTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted) return;
      if (_menuOpen) {
        _closeMenu();
      } else if (_speedMenuOpen) {
        _closeSpeedMenu();
      }
    });
  }

  void _closeMenu() {
    _menuHideTimer?.cancel();
    _stampOverlayClose();
    setState(() {
      _menuOpen = false;
      _menuStack.clear();
    });
    _rootFocus.requestFocus(); // hand D-pad back to the player controls
  }

  // ── Netflix control button row + episode picker ─────────────────────────────

  /// Drop D-pad focus into the control button row (from the root). The row
  /// stays visible while focused (see [_bumpControls]).
  void _enterControlRow() {
    _bumpControls();
    setState(() => _controlRowFocused = true);
    _rowFocusNodes.first.requestFocus();
  }

  /// Hand focus back to the player root — OK=play/pause, ◀▶=seek again.
  void _exitControlRow() {
    setState(() => _controlRowFocused = false);
    _rootFocus.requestFocus();
    _bumpControls();
  }

  void _openEpisodes() {
    setState(() {
      _episodesOpen = true;
      _episodeRangeIndex = episodeRangeIndex(_index);
    });
    // Move focus into the picker once it's mounted (autofocus can't steal it
    // from the root); the current episode is the autofocus target in the scope.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _episodesOpen) _episodesScope.requestFocus();
    });
  }

  void _closeEpisodes() {
    if (!_episodesOpen) return;
    _stampOverlayClose();
    setState(() => _episodesOpen = false);
    _rootFocus.requestFocus();
  }

  void _playEpisodeAt(int i) {
    if (i < 0 || i >= _episodes.length) {
      _closeEpisodes();
      return;
    }
    if (i != _index) {
      setState(() => _index = i);
      _loadEpisode();
    }
    _closeEpisodes();
  }

  void _onTracksChanged() {
    _maybeApplySubPref();
    if (_menuOpen && mounted) setState(() {});
  }

  Future<void> _maybeApplySubPref() async {
    final c = _c;
    if (c == null || _subApplied) return;
    final tracks = c.textTracks.value;
    if (tracks.isEmpty && c.duration.value <= 0) return; // not ready yet
    _subApplied = true;
    final pref = sl<PlaybackPrefs>().subtitlePreference;
    final d = decideSubtitle(textTracks: tracks, pref: pref);
    switch (d.action) {
      case TvSubAction.off:
        c.selectTextTrack(null);
        break;
      case TvSubAction.auto:
        break; // leave ExoPlayer's default
      case TvSubAction.select:
        c.selectTextTrack(d.track!.id);
        break;
      case TvSubAction.download:
        if (!_subDownloadTried && sl<PlaybackPrefs>().autoDownloadSubtitles) {
          await _downloadAndAttach(d.language!);
        }
        break;
    }
  }

  Future<void> _downloadAndAttach(Language lang) async {
    _subDownloadTried = true;
    try {
      final results = await SubtitleDownloadService().find(
        title: widget.showTitle,
        iso2: lang.iso2,
        iso1: lang.iso1,
      );
      if (results.isEmpty || !mounted) return;
      final r = results.first;
      _subDownloads.add(
        TvSubtitleConfig(
          url: r.url,
          lang: lang.iso1,
          label: lang.name,
          mime: subtitleMime(null, url: r.url),
        ),
      );
      // Re-open the current source with the added subtitle, keeping position
      // AND the download list (keepDownloads: true). Then re-arm the pref pass
      // so the now-present downloaded track gets selected on the next
      // onTracksChanged (the _subDownloadTried guard prevents a re-download loop).
      final src = _activeSource;
      if (src != null) {
        await _open(
          src,
          seekToMs: _c?.position.value ?? 0,
          keepDownloads: true,
        );
        _subApplied = false;
      }
    } catch (_) {}
  }

  void _maybeSaveProgress() {
    final c = _c;
    final ep = _ep;
    if (c == null || ep == null || c.duration.value <= 0) return;
    final pos = c.position.value;
    if ((pos - _lastSavedMs).abs() < 5000) return; // throttle: every 5s
    _lastSavedMs = pos;
    widget.resume.save(
      widget.sourceId,
      _resumeShowId,
      ep.id,
      Duration(milliseconds: pos),
      Duration(milliseconds: c.duration.value),
    );
    _saveHistory();
  }

  /// Records the current episode into Continue Watching (mirrors the phone
  /// player's WatchHistory write). Without this, ExoPlayer-played titles never
  /// appear in the Continue Watching rail. [flush] forces the throttled cloud
  /// push on close.
  void _saveHistory({bool flush = false}) {
    final c = _c;
    final ep = _ep;
    if (c == null || ep == null || c.duration.value <= 0) return;
    sl<WatchHistory>().save(
      HistoryEntry(
        sourceId: widget.sourceId,
        showId: widget.showUrl ?? widget.sourceId,
        showTitle: widget.showTitle ?? '',
        cover: widget.cover,
        coverHeaders: widget.coverHeaders,
        showUrl: widget.showUrl ?? '',
        category: _category,
        episodeId: ep.id,
        episodeNumber: ep.number,
        episodeUrl: ep.url,
        position: Duration(milliseconds: c.position.value),
        duration: Duration(milliseconds: c.duration.value),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        malId: widget.malId,
      ),
      flush: flush,
    );
  }

  void _onEnded() {
    if (_c?.ended.value != true) return;
    _maybeScrobble(force: true);
    if (_index >= _episodes.length - 1) return;
    if (sl<PlaybackPrefs>().autoplayNext) {
      _startUpNext();
    }
  }

  void _startUpNext() {
    _upNextCountdown = 5;
    if (mounted) setState(() {});
    // Move focus onto the card so OK=play-now / Back=cancel work.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _upNextCountdown != null) _upNextFocus.requestFocus();
    });
    _upNextTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final next = (_upNextCountdown ?? 1) - 1;
      if (next <= 0) {
        t.cancel();
        _cancelUpNext();
        _next(auto: true);
      } else {
        setState(() => _upNextCountdown = next);
      }
    });
  }

  void _cancelUpNext() {
    _upNextTimer?.cancel();
    _upNextTimer = null;
    _stampOverlayClose();
    if (mounted) setState(() => _upNextCountdown = null);
    _rootFocus.requestFocus(); // hand D-pad back to the player
  }

  /// Advance to the next episode. When auto-skip filler is on, jumps past
  /// consecutive fillers for both up-next and the Next button.
  void _next({bool auto = false}) {
    final target = nextAutoplayIndex(
      currentIndex: _index,
      episodes: _episodes,
      fillerEps: _fillerEps.value,
      autoSkipFiller: sl<PlaybackPrefs>().autoSkipFiller,
    );
    if (target == null) return;
    setState(() => _index = target);
    _loadEpisode();
  }

  void _prev() {
    if (_index <= 0) return;
    setState(() => _index--);
    _loadEpisode();
  }

  void _togglePlay() {
    final c = _c;
    if (c == null) return;
    c.playing.value ? c.pause() : c.play();
  }

  void _seekBy(int deltaMs) {
    final c = _c;
    if (c == null) return;
    final target = (c.position.value + deltaMs).clamp(
      0,
      c.duration.value == 0 ? 1 << 31 : c.duration.value,
    );
    c.seek(target);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    final k = e.logicalKey;
    // While an overlay (menu / online search / up-next) is up, it owns the
    // D-pad: let its focused widget + traversal handle keys, don't eat them.
    if (_menuOpen ||
        _speedMenuOpen ||
        _episodesOpen ||
        _searchResults != null ||
        _upNextCountdown != null) {
      if (_holdingSpeed) {
        _endHoldSpeed(); // don't leave 2× stuck if a menu opens
      }
      return KeyEventResult.ignored;
    }
    // Back / Escape: hide the controls first, then exit. Handled HERE (before any
    // _bumpControls) so a Back delivered as a key event can't re-show the
    // controls and trap the user in the player — that was the "can't exit" bug.
    if (k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.escape) {
      // One press = one action. Non-exit actions run on the DOWN; the EXIT pop
      // is deferred to the UP — if the DOWN popped, the UP of the same press
      // would land on the screen BELOW and pop that too (player + detail gone
      // in one press). Every phase returns handled so nothing falls through to
      // the system as a second (route-pop) back action.
      if (e is KeyDownEvent) {
        _backPressConsumed = true;
        if (!_justClosedOverlay && _controlsVisible) {
          _controlsHideTimer?.cancel();
          setState(() => _controlsVisible = false);
        } else if (!_justClosedOverlay) {
          _backPressConsumed = false; // nothing to do now → exit on the UP
        }
        return KeyEventResult.handled;
      }
      if (e is KeyUpEvent && !_backPressConsumed) {
        _backPressConsumed = true;
        if (mounted) Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    // Center OK: a tap plays/pauses, a HOLD runs temporary 2× (YouTube-style).
    // The toggle is deferred to key-up so holding speeds up instead of pausing;
    // a hold is detected by the key-repeat that only a held button emits.
    if (okKeys.contains(k)) {
      if (e is KeyDownEvent) {
        _bumpControls();
        return KeyEventResult.handled;
      }
      if (e is KeyRepeatEvent) {
        _startHoldSpeed();
        return KeyEventResult.handled;
      }
      if (e is KeyUpEvent) {
        _holdingSpeed ? _endHoldSpeed() : _togglePlay();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    _bumpControls(); // any input reveals the controls + resets the hide timer
    if (k == LogicalKeyboardKey.arrowRight) {
      _seekBy(10000);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-10000);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackNext) {
      _next();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackPrevious) {
      _prev();
      return KeyEventResult.handled;
    }
    // ▼ drops focus into the Netflix control button row; ▲ / context-menu jump
    // straight to the Audio & Subtitles menu (quick access preserved).
    if (k == LogicalKeyboardKey.arrowDown) {
      _enterControlRow();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.contextMenu ||
        k == LogicalKeyboardKey.arrowUp) {
      _openMenu();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Center OK held → play at 2× until released (mirrors YouTube's hold-to-2×
  /// and the phone player's long-press). Drives the controller directly so the
  /// boost is never persisted as the user's chosen speed.
  void _startHoldSpeed() {
    if (_holdingSpeed) return;
    _holdingSpeed = true;
    _bumpControls();
    _c?.setPlaybackSpeed(2.0);
  }

  void _endHoldSpeed() {
    if (!_holdingSpeed) return;
    _holdingSpeed = false;
    _c?.setPlaybackSpeed(_speed); // back to the user's chosen speed
    _bumpControls();
  }

  @override
  void dispose() {
    // Android pauses (and often disposes) this screen when the Exo surface
    // attaches — that is not leaving the player. A delayed clear here races
    // duration and wipes the Discord progress bar.
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != AppLifecycleState.paused &&
        life != AppLifecycleState.hidden &&
        life != AppLifecycleState.inactive) {
      _announceBrowsing();
    }
    _loadGen++; // supersede any in-flight torrent resolve so it stops itself
    _stopTorrent();
    _menuHideTimer?.cancel();
    _controlsHideTimer?.cancel();
    _discordPauseTimer?.cancel();
    _upNextTimer
        ?.cancel(); // cancel directly — _cancelUpNext setStates/refocuses
    final c = _c;
    if (c != null) {
      // Persist final position before releasing.
      final ep = _ep;
      if (ep != null && c.duration.value > 0) {
        widget.resume.save(
          widget.sourceId,
          _resumeShowId,
          ep.id,
          Duration(milliseconds: c.position.value),
          Duration(milliseconds: c.duration.value),
        );
        _saveHistory(flush: true);
      }
      c.dispose();
    }
    _dio.close();
    WakelockPlus.disable(); // release the keep-awake lock on exit
    _rootFocus.dispose();
    _upNextFocus.dispose();
    for (final n in _rowFocusNodes) {
      n.dispose();
    }
    _episodesScope.dispose();
    _selectedRangeFocus.dispose();
    _currentEpisodeFocus.dispose();
    _fillerEps.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final overlayOpen =
        _menuOpen ||
        _speedMenuOpen ||
        _episodesOpen ||
        _searchResults != null ||
        _upNextCountdown != null;
    return PopScope(
      // While an overlay is up, Back closes IT (the TV remote Back is a route
      // pop, not a key event, so this — not the menu's onKeyEvent — is what
      // actually catches it); only pop the player when nothing is open.
      // Netflix-style Back ladder: dismiss whatever is showing before exiting.
      // An open overlay closes first; then the visible controls/progress bar
      // hide; only a Back with nothing on screen pops the player.
      canPop: !overlayOpen && !_controlsVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_searchResults != null) {
          _stampOverlayClose();
          setState(() => _searchResults = null);
          _rootFocus.requestFocus();
        } else if (_episodesOpen) {
          _closeEpisodes();
        } else if (_menuOpen) {
          _closeMenu();
        } else if (_speedMenuOpen) {
          _closeSpeedMenu();
        } else if (_upNextCountdown != null) {
          _cancelUpNext();
        } else if (_controlsVisible && !_justClosedOverlay) {
          // (the guard: one Back press = one ladder rung, never two)
          _controlsHideTimer?.cancel();
          setState(() => _controlsVisible = false);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          onFocusChange: (f) {
            // Root regained focus (e.g. ▲ out of the row, or an overlay closed) —
            // clear the row flag so the auto-hide resumes.
            if (f && _controlRowFocused) {
              setState(() => _controlRowFocused = false);
            }
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: PlatformViewLink(
                  viewType: 'zangetsu/exoplayer_view',
                  surfaceFactory: (context, controller) => AndroidViewSurface(
                    controller: controller as AndroidViewController,
                    gestureRecognizers:
                        const <Factory<OneSequenceGestureRecognizer>>{},
                    hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                  ),
                  onCreatePlatformView: (params) {
                    // initExpensiveAndroidView (Hybrid Composition) + the native
                    // default SurfaceView PlayerView — the exact combination
                    // that shipped WORKING in v1.7.0. TextureView + texture-layer
                    // composition were tried and made video BLACK on some TVs,
                    // so both are reverted.
                    final controller =
                        PlatformViewsService.initExpensiveAndroidView(
                            id: params.id,
                            viewType: 'zangetsu/exoplayer_view',
                            layoutDirection: TextDirection.ltr,
                            creationParams: sl<PlaybackPrefs>().exoBufferParams,
                            creationParamsCodec: const StandardMessageCodec(),
                            onFocus: () => params.onFocusChanged(true),
                          )
                          ..addOnPlatformViewCreatedListener(
                            params.onPlatformViewCreated,
                          )
                          ..addOnPlatformViewCreatedListener(_onViewCreated)
                          ..create();
                    return controller;
                  },
                ),
              ),
              // Touchscreen: tap empty video to show/hide chrome. Sits above the
              // PlatformView and under the controls overlay so visible pills still
              // receive taps.
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleControlsFromTouch,
                ),
              ),
              if (_error != null)
                Center(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                  ),
                ),
              if (_torrentPhase != null)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        _torrentPhase!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              // Centered buffering spinner — shown even when the controls are
              // hidden, so a stall during playback always reads.
              if (_c != null)
                ValueListenableBuilder<bool>(
                  valueListenable: _c!.buffering,
                  builder: (_, buf, _) => buf && _error == null
                      ? const Center(
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              if (_c != null && _controlsVisible) _controlsOverlay(_c!),
              if (_episodesOpen && _c != null) _episodesOverlay(),
              if (_c != null)
                Positioned(
                  right: 40,
                  bottom: 120,
                  child: ValueListenableBuilder<int>(
                    valueListenable: _c!.position,
                    builder: (_, pos, _) {
                      final children = <Widget>[];
                      final skip = sl<PlaybackPrefs>().skipIntro
                          ? activeSkipInterval(_skips, pos)
                          : null;
                      if (skip != null) {
                        children.add(
                          _pillButton(
                            skipLabel(skip.type),
                            () => _c?.seek(skip.end.inMilliseconds),
                          ),
                        );
                      }
                      // The manual "+Ns" jump pill rides with the controls — it
                      // fades out on the same 5s timer instead of sitting on the
                      // video the whole episode. (The AniSkip pill above still
                      // shows for its interval, Netflix-style.)
                      if (_controlsVisible) {
                        final secs = sl<PlaybackPrefs>().megaSkipSeconds;
                        final showMega = sl<PlaybackPrefs>().megaSkip;
                        children.add(
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _speedPill(),
                              if (showMega) ...[
                                const SizedBox(width: 8),
                                _pillButton('+${secs}s', () {
                                  final c = _c;
                                  if (c != null) {
                                    c.seek(c.position.value + secs * 1000);
                                  }
                                }),
                              ],
                            ],
                          ),
                        );
                      }
                      if (children.isEmpty) return const SizedBox.shrink();
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final w in children)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: w,
                            ),
                        ],
                      );
                    },
                  ),
                ),
              if (_upNextCountdown != null && _autoNextIndex != null)
                Positioned(
                  right: 40,
                  bottom: 160,
                  child: Focus(
                    focusNode: _upNextFocus,
                    onKeyEvent: (_, e) {
                      if (e is! KeyDownEvent) return KeyEventResult.ignored;
                      if (okKeys.contains(e.logicalKey)) {
                        _cancelUpNext();
                        _next(auto: true);
                        return KeyEventResult.handled;
                      }
                      if (e.logicalKey == LogicalKeyboardKey.goBack ||
                          e.logicalKey == LogicalKeyboardKey.escape) {
                        _cancelUpNext();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: Builder(
                      builder: (context) {
                        final nextIdx = _autoNextIndex!;
                        final nextEp = _episodes[nextIdx];
                        final n = nextEp.number?.toInt() ?? (nextIdx + 1);
                        final nextTitle =
                            episodeDisplayTitle(nextEp, number: n) ??
                            'Episode $n';
                        return Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: AppColors.accent, width: 2),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Up next: $nextTitle',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Playing in $_upNextCountdown…  (OK to play now, Back to cancel)',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              if (_speedMenuOpen)
                TvTrackMenu(
                  key: const ValueKey('menu-speed'),
                  title: context.l10n.speed,
                  options: [
                    for (final s in kTvSpeeds)
                      TvMenuOption(
                        label: s == 1.0 ? context.l10n.normalSpeed : '$s×',
                        selected: (_speed - s).abs() < 0.001,
                        onSelect: () => _setSpeed(s),
                      ),
                  ],
                  onClose: _closeSpeedMenu,
                  onInteract: _bumpMenuHide,
                ),
              if (_menuOpen && _c != null)
                TvTrackMenu(
                  key: ValueKey('menu-$_menuTitle-${_menuStack.length}'),
                  title: _menuTitle,
                  options: _buildMenuOptions(_c!),
                  onClose: _popOrCloseMenu,
                  onInteract: _bumpMenuHide,
                ),
              if (_searchResults != null)
                TvTrackMenu(
                  title: context.l10n.onlineSubtitles,
                  onClose: () {
                    setState(() => _searchResults = null);
                    _rootFocus.requestFocus();
                  },
                  options: [
                    for (final r in _searchResults!)
                      TvMenuOption(
                        label: r.name,
                        trailing: r.language,
                        showCheck: false,
                        onSelect: () => _applySearchResult(r),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Netflix-style Hybrid controls: title + episode label under a top scrim,
  /// and a polished scrubber + focusable button row under a bottom scrim. OK
  /// still play/pauses and ◀▶ still seek from the root; ▼ drops into the row.
  Widget _controlsOverlay(TvExoController c) {
    final ep = _ep;
    final epLabel = ep == null
        ? null
        : episodePresenceDetails(ep, fallbackNumber: _index + 1);
    final buttons = <({IconData icon, String label, VoidCallback onTap})>[
      (
        icon: Icons.video_library_outlined,
        label: context.l10n.episodes,
        onTap: _openEpisodes,
      ),
      (icon: Icons.subtitles_outlined, label: context.l10n.audioSubs, onTap: _openMenu),
      if (_index < _episodes.length - 1)
        (icon: Icons.skip_next_rounded, label: context.l10n.nextEpisode, onTap: _next),
    ];
    return Positioned.fill(
      child: Stack(
        children: [
          Column(
            children: [
              // ── Top scrim + title / episode ────────────────────────────────────
              GestureDetector(
                onTap: _toggleControlsFromTouch,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(48, 36, 48, 56),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.showTitle ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (epLabel != null) ...[
                        const SizedBox(height: 4),
                        ValueListenableBuilder<Set<int>>(
                          valueListenable: _fillerEps,
                          builder: (context, fillers, _) {
                            final n = ep?.number?.toInt();
                            final isFiller = n != null && fillers.contains(n);
                            return Row(
                              children: [
                                Text(
                                  epLabel,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.7),
                                    fontSize: 16,
                                  ),
                                ),
                                if (isFiller) ...[
                                  const SizedBox(width: 8),
                                  const TagBadge(text: 'FILLER'),
                                ],
                              ],
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // Empty mid-video: tap play/pauses while chrome is up.
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _toggleControlsFromTouch,
                ),
              ),
              // ── Bottom scrim + scrubber + button row ───────────────────────────
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(48, 44, 48, 34),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black, Colors.transparent],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: c.position,
                      builder: (_, pos, _) => ValueListenableBuilder<int>(
                        valueListenable: c.duration,
                        builder: (_, dur, _) {
                          final displayPos = _scrubMs ?? pos;
                          final frac = dur > 0
                              ? (displayPos / dur).clamp(0.0, 1.0)
                              : 0.0;
                          return Row(
                            children: [
                              Text(
                                _fmt(displayPos),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                // ExcludeFocus: D-pad must not land on the
                                // slider (◀▶ still seek from the root).
                                child: ExcludeFocus(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 6,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 8,
                                      ),
                                      overlayShape:
                                          const RoundSliderOverlayShape(
                                            overlayRadius: 14,
                                          ),
                                      activeTrackColor: AppColors.accent,
                                      inactiveTrackColor: Colors.white24,
                                      thumbColor: AppColors.accent,
                                      overlayColor: AppColors.accent
                                          .withValues(alpha: 0.25),
                                    ),
                                    child: Slider(
                                      value: frac.toDouble(),
                                      onChangeStart: dur > 0
                                          ? (_) {
                                              _controlsHideTimer?.cancel();
                                              setState(() {
                                                _scrubbing = true;
                                                _scrubMs = displayPos;
                                              });
                                            }
                                          : null,
                                      onChanged: dur > 0
                                          ? (v) {
                                              setState(() {
                                                _scrubMs = (v * dur).round();
                                              });
                                            }
                                          : null,
                                      onChangeEnd: dur > 0
                                          ? (v) {
                                              final target = (v * dur).round();
                                              c.seek(target);
                                              setState(() {
                                                _scrubbing = false;
                                                _scrubMs = null;
                                              });
                                              _bumpControls();
                                            }
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _fmt(dur),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var i = 0; i < buttons.length; i++)
                          _controlRowButton(
                            i,
                            buttons.length,
                            buttons[i].icon,
                            buttons[i].label,
                            buttons[i].onTap,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Center play glyph while paused (matches native remote OK feedback).
          ValueListenableBuilder<bool>(
            valueListenable: c.playing,
            builder: (_, playing, _) {
              if (playing) return const SizedBox.shrink();
              return IgnorePointer(
                child: Center(
                  child: Container(
                    width: 86,
                    height: 86,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 48,
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// A focusable pill in the control row. ◀▶ moves along the row, OK activates,
  /// ▲/Back hands focus back to the player root. Returns `handled` for the
  /// arrows so the root's seek handler never fires while the row is focused.
  Widget _controlRowButton(
    int index,
    int total,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    // container: true makes this the one semantics node for the whole
    // button (mirrors TvFocusable's own Semantics wrap) — the Focus below
    // adds its own focusable/focused bits which merge up into this node
    // instead of forming a second one.
    return Semantics(
      container: true,
      label: label,
      button: true,
      onTap: onTap,
      child: Focus(
        focusNode: _rowFocusNodes[index],
        onKeyEvent: (n, e) {
          if (e is! KeyDownEvent) return KeyEventResult.ignored;
          final k = e.logicalKey;
          if (okKeys.contains(k)) {
            onTap();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.arrowLeft) {
            if (index > 0) _rowFocusNodes[index - 1].requestFocus();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.arrowRight) {
            if (index < total - 1) _rowFocusNodes[index + 1].requestFocus();
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.arrowUp ||
              k == LogicalKeyboardKey.goBack ||
              k == LogicalKeyboardKey.escape) {
            _exitControlRow();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final focused = Focus.of(context).hasFocus;
            return GestureDetector(
              onTap: () {
                setState(() => _controlRowFocused = true);
                _rowFocusNodes[index].requestFocus();
                onTap();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                margin: const EdgeInsets.symmetric(horizontal: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: focused
                      ? AppColors.accent
                      : Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 20, color: Colors.white),
                    const SizedBox(width: 8),
                    // The Semantics above already announces the label —
                    // exclude this sibling so TalkBack doesn't say it twice.
                    ExcludeSemantics(
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Full-screen episode picker (opened from the control row's Episodes button).
  Widget _episodesOverlay() {
    final total = _episodes.length;
    final rangeCount = episodeRangeCount(total);
    final showRanges = rangeCount > 1;
    final maxRange = rangeCount == 0 ? 0 : rangeCount - 1;
    final rangeIndex = _episodeRangeIndex.clamp(0, maxRange);
    final slice = episodeRangeSlice(rangeIndex, total);
    final visibleStart = slice.start;
    final visibleCount = slice.end - slice.start;

    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: 520,
      child: Container(
        color: Colors.black.withValues(alpha: 0.66),
        padding: const EdgeInsets.fromLTRB(30, 34, 30, 34),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Episodes',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: FocusScope(
                node: _episodesScope,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showRanges)
                      TvEpisodeRangeChips(
                        axis: Axis.vertical,
                        count: rangeCount,
                        selected: rangeIndex,
                        selectedChipFocusNode: _selectedRangeFocus,
                        episodeReturnFocusNode: _currentEpisodeFocus,
                        labelFor: (i) => episodeRangeLabel(_episodes, i),
                        onSelect: (i) =>
                            setState(() => _episodeRangeIndex = i),
                      ),
                    if (showRanges) const SizedBox(width: 16),
                    Expanded(
                      child: ValueListenableBuilder<Set<int>>(
                        valueListenable: _fillerEps,
                        builder: (context, fillers, _) {
                          return ListView.builder(
                            primary: false,
                            cacheExtent: 2000,
                            itemCount: visibleCount,
                            itemBuilder: (context, localI) {
                              final i = visibleStart + localI;
                              final ep = _episodes[i];
                              final n = ep.number?.toInt() ?? (i + 1);
                              final title = episodeDisplayTitle(ep, number: n) ??
                                  'Episode $n';
                              final current = i == _index;
                              final isFiller = fillers.contains(n);
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Focus(
                                  onKeyEvent: (_, event) {
                                    if (!showRanges) {
                                      return KeyEventResult.ignored;
                                    }
                                    if (event is KeyDownEvent &&
                                        event.logicalKey ==
                                            LogicalKeyboardKey.arrowLeft) {
                                      _selectedRangeFocus.requestFocus();
                                      return KeyEventResult.handled;
                                    }
                                    return KeyEventResult.ignored;
                                  },
                                  child: TvFocusable(
                                    autofocus: current,
                                    focusNode:
                                        current ? _currentEpisodeFocus : null,
                                    scale: 1.0,
                                    onTap: () => _playEpisodeAt(i),
                                    child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 14,
                                    ),
                                    decoration: BoxDecoration(
                                      color: current
                                          ? AppColors.accent.withValues(
                                              alpha: 0.22,
                                            )
                                          : Colors.white.withValues(alpha: 0.06),
                                      borderRadius: BorderRadius.circular(10),
                                      border: current
                                          ? Border.all(
                                              color: AppColors.accent,
                                              width: 1.5,
                                            )
                                          : null,
                                    ),
                                    child: Row(
                                      children: [
                                        if (current) ...[
                                          const Icon(
                                            Icons.play_arrow_rounded,
                                            color: Colors.white,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        Expanded(
                                          child: Text(
                                            'Episode $n · $title',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: current
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                        if (isFiller) ...[
                                          const SizedBox(width: 8),
                                          const TagBadge(text: 'FILLER'),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmt(int ms) {
    final s = ms ~/ 1000;
    final m = s ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  Widget _pillButton(String label, VoidCallback onTap) {
    return Focus(
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && okKeys.contains(e.logicalKey)) {
          onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: () {
              Focus.of(context).requestFocus();
              onTap();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: focused ? AppColors.accent : Colors.white38,
                  width: 2,
                ),
              ),
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _speedPill() {
    final label = (_speed - 1.0).abs() < 0.001 ? '1×' : '$_speed×';
    return Focus(
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (okKeys.contains(e.logicalKey)) {
          _openSpeedMenu();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: () {
              Focus.of(context).requestFocus();
              _openSpeedMenu();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: focused || _speedMenuOpen
                      ? AppColors.accent
                      : Colors.white38,
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.speed,
                    size: 18,
                    color: Colors.white.withValues(alpha: 0.95),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Drill-in pages for the Flutter TV Settings side panel.
enum _TvSettingsPage {
  root,
  servers,
  quality,
  audio,
  subs,
  captionStyle,
  captionSize,
  captionColor,
  captionEdge,
  captionBg,
  captionFont,
  captionPos,
  volume,
}
