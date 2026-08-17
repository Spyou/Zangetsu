import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/brand_loader.dart';
import 'drm_player_screen.dart';
import 'player_controller.dart';
import 'player_screen.dart';
import 'watch_comments_placeholder.dart';
import 'watch_mini_controls.dart';

/// Portrait host for an episode: video small at the top, tabs underneath.
/// Owns the [PlayerCubit] — going fullscreen hands the same cubit to
/// PlayerScreen so playback carries straight over.
class WatchScreen extends StatefulWidget {
  const WatchScreen({
    super.key,
    required this.sourceId,
    this.episodes = const [],
    this.startIndex = 0,
    this.episodesResolver,
    this.resumeEpisodeId,
    this.resumeEpisodeNumber,
    required this.resume,
    required this.resolveSources,
    this.pollSources,
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
    this.resumePosition = Duration.zero,
  });

  final String sourceId;
  final List<Episode> episodes;
  final int startIndex;

  /// Either pass [episodes] directly, or an [episodesResolver] that the
  /// screen navigates to INSTANTLY and resolves behind a branded loader
  /// (mirrors PlayerScreen's instant-nav path — no blocking await before the
  /// push). [resumeEpisodeId] picks the start index once the resolver
  /// returns, falling back to [resumeEpisodeNumber] when a provider
  /// regenerated ids.
  final Future<List<Episode>> Function()? episodesResolver;
  final String? resumeEpisodeId;
  final double? resumeEpisodeNumber;

  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;

  /// Reads the links that finish resolving AFTER [resolveSources] returned —
  /// see PlayerCubit's own doc. Null keeps the previous behaviour (one
  /// batch, no poll).
  final Future<({List<VideoSource> sources, bool done})> Function(
    String episodeUrl,
  )?
  pollSources;

  final WatchHistory? history;
  final String? showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String? showUrl;
  final String? category;
  final int? malId;
  final String? scrobbleTitle;

  /// TMDB/IMDB ids — feed Simkl scrobbling and the keyless subtitle
  /// auto-download fallback in [PlayerCubit].
  final int? tmdbId;
  final bool tmdbIsTv;
  final String? imdbId;

  final List<String> availableCategories;
  final Duration resumePosition;

  @override
  State<WatchScreen> createState() => WatchScreenState();
}

class WatchScreenState extends State<WatchScreen> {
  late final PlayerCubit _c;

  /// False while an [WatchScreen.episodesResolver] is still resolving — [_c]
  /// isn't created yet, so build() must not touch it until this flips true.
  bool _ready = false;

  bool _showControls = true;
  Timer? _hide;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playSub;
  Duration _pos = Duration.zero;
  bool _playing = false;
  bool _inFullscreen = false;

  /// Set when we come back from fullscreen. Blocks the turn-the-phone path
  /// until the phone is actually portrait again, so backing out while still
  /// holding it sideways doesn't bounce straight back into fullscreen.
  bool _armOnPortrait = false;

  void _bumpControls() {
    setState(() => _showControls = true);
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  @override
  void initState() {
    super.initState();
    allowRotation();
    // Default external player: hand the stream off to the chosen app instead
    // of starting the portrait player. Same decision PlayerScreen makes in its
    // own initState — reused via attemptExternalPlayerLaunch so the two hosts
    // can't drift apart (and so fullscreen's own check never fires a second,
    // double-playing launch on top of this one).
    if (Platform.isAndroid &&
        sl<PlaybackPrefs>().externalPlayerPackage.isNotEmpty) {
      _launchExternalThenLeave();
      return;
    }
    _startInApp();
  }

  void _startInApp() {
    if (widget.episodes.isEmpty && widget.episodesResolver != null) {
      _resolveThenStart(); // instant nav: resolve behind the branded loader
    } else {
      _startSession(widget.episodes, widget.startIndex);
    }
  }

  Future<void> _launchExternalThenLeave() async {
    final result = await attemptExternalPlayerLaunch(
      episodes: widget.episodes,
      episodesResolver: widget.episodesResolver,
      startIndex: widget.startIndex,
      resumeEpisodeId: widget.resumeEpisodeId,
      resumeEpisodeNumber: widget.resumeEpisodeNumber,
      resolveSources: widget.resolveSources,
      category: widget.category,
      malId: widget.malId,
      scrobbleTitle: widget.scrobbleTitle,
      tmdbId: widget.tmdbId,
      tmdbIsTv: widget.tmdbIsTv,
      imdbId: widget.imdbId,
      showTitle: widget.showTitle,
    );
    if (!mounted) return;
    if (result.launched) {
      Navigator.of(context).maybePop();
      return;
    }
    // Fallback: unlike the initState path above, this runs after the branded
    // loader's already on screen, so starting the session needs a setState
    // to actually repaint (matches _resolveThenStart's own wrapping below).
    setState(_startInApp);
    if (result.message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(result.message!)));
    }
  }

  /// Mirrors PlayerScreen's `_resolveThenStart` — resolves the episode list,
  /// picks the resume episode by id (falling back to number), then starts
  /// the session. On empty/failed resolve, just leaves (no join-room case
  /// here, unlike PlayerScreen, so there's nothing else to show).
  Future<void> _resolveThenStart() async {
    try {
      final eps = await widget.episodesResolver!();
      if (!mounted) return;
      if (eps.isEmpty) {
        Navigator.of(context).maybePop();
        return;
      }
      var idx = 0;
      if (widget.resumeEpisodeId != null) {
        var i = eps.indexWhere((e) => e.id == widget.resumeEpisodeId);
        if (i < 0 && widget.resumeEpisodeNumber != null) {
          i = eps.indexWhere((e) => e.number == widget.resumeEpisodeNumber);
        }
        if (i >= 0) idx = i;
      }
      setState(() => _startSession(eps, idx));
    } catch (_) {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  void _startSession(List<Episode> episodes, int startIndex) {
    _c = PlayerCubit(
      sourceId: widget.sourceId,
      episodes: episodes,
      resume: widget.resume,
      resolveSources: widget.resolveSources,
      pollSources: widget.pollSources,
      dio: sl<Dio>(),
      history: widget.history,
      showTitle: widget.showTitle,
      cover: widget.cover,
      coverHeaders: widget.coverHeaders,
      showUrl: widget.showUrl,
      category: widget.category,
      malId: widget.malId,
      scrobbleTitle: widget.scrobbleTitle,
      tmdbId: widget.tmdbId,
      tmdbIsTv: widget.tmdbIsTv,
      imdbId: widget.imdbId,
      availableCategories: widget.availableCategories,
      initialResume: widget.resumePosition,
      onDrmSource: _handoffToNativeDrm,
    )..init(startIndex);
    _posSub = _c.player.stream.position.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _playSub = _c.player.stream.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    });
    _bumpControls();
    _ready = true;
  }

  // A DRM (clearkey CENC/DASH) source can't play in mpv. Mirrors PlayerScreen's
  // _handoffToNativeDrm exactly: the cubit's onDrmSource is bound once here, at
  // creation, so this fires regardless of whether the portrait player or the
  // pushed-on-top fullscreen PlayerScreen (which adopts this same cubit and
  // never rebinds the callback) is what's currently visible.
  bool _drmHandedOff = false;
  Future<void> _handoffToNativeDrm(VideoSource drm) async {
    if (_drmHandedOff) return; // _open can fire more than once (switch/failover)
    _drmHandedOff = true;
    await _c.player.pause(); // don't buffer the idle mpv player behind the DRM one
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DrmPlayerScreen(
          sources: _c.state.sources,
          initial: drm,
          title: widget.showTitle,
          subtitle: _episodeLabelOrNull(),
        ),
      ),
    );
    if (mounted) Navigator.of(context).maybePop();
  }

  String? _episodeLabelOrNull() {
    final eps = _c.episodes;
    final i = _c.state.currentIndex;
    if (i < 0 || i >= eps.length) return null;
    final e = eps[i];
    return e.title.isNotEmpty ? e.title : null;
  }

  /// Empty list = let Android's own auto-rotate setting decide. That's how we
  /// get "sensor only when auto-rotate is on" without reading the setting.
  void allowRotation() => SystemChrome.setPreferredOrientations(const []);

  Future<void> _goFullscreen() async {
    if (_inFullscreen || !_ready) return;
    _inFullscreen = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          cubit: _c,                       // hand over the running player
          sourceId: widget.sourceId,
          episodes: _c.episodes,
          startIndex: _c.state.currentIndex,
          resume: widget.resume,
          resolveSources: widget.resolveSources,
          pollSources: widget.pollSources,
          history: widget.history,
          showTitle: widget.showTitle,
          cover: widget.cover,
          coverHeaders: widget.coverHeaders,
          showUrl: widget.showUrl,
          category: widget.category,
          malId: widget.malId,
          scrobbleTitle: widget.scrobbleTitle,
          tmdbId: widget.tmdbId,
          tmdbIsTv: widget.tmdbIsTv,
          imdbId: widget.imdbId,
          availableCategories: widget.availableCategories,
        ),
      ),
    );
    _inFullscreen = false;
    // Coming back while the phone is still physically sideways would put us
    // straight back in — the orientation check below sees landscape again the
    // moment rotation is re-armed. Wait until it's actually portrait before
    // arming the sensor path again; the button keeps working either way.
    _armOnPortrait = true;
    // PlayerScreen's dispose pins portraitUp. Re-open rotation or turning the
    // phone will never work again for the rest of this session.
    if (mounted) allowRotation();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _posSub?.cancel();
    _playSub?.cancel();
    // We created it, so we close it. PlayerScreen never closes an injected
    // one. Guarded on _ready — a resolve that's still in flight (or that
    // failed/emptied and already popped) never created a cubit to close.
    if (_ready) _c.close();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  /// Exposed so the fullscreen route can hand the running cubit back.
  PlayerCubit get cubit => _c;

  @override
  Widget build(BuildContext context) {
    // Still resolving the episode list (instant-nav path) — show the same
    // branded loader PlayerScreen shows, instead of touching the
    // not-yet-created cubit.
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: BrandLoader(label: 'Loading…')),
      );
    }
    final episodes = _c.episodes;
    final multi = episodes.length > 1;
    // Only fires when Android's auto-rotate is on — with it off, the app is
    // never handed a landscape constraint in the first place.
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (!landscape) _armOnPortrait = false; // back upright — sensor path is live again
    if (landscape && !_inFullscreen && !_armOnPortrait) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goFullscreen());
    }
    return DefaultTabController(
      length: multi ? 2 : 1,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: Column(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                // A failed resolve/playback needs to surface here — without
                // this, a dead source just leaves a frozen black box that
                // looks like the app hung. Mirrors PlayerScreen's error state
                // (icon + message + Try again), scaled to the smaller box.
                child: BlocBuilder<PlayerCubit, PlayerState>(
                  bloc: _c,
                  builder: (context, state) {
                    if (state.error != null) {
                      return ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.error_outline,
                                  size: 28,
                                  color: AppColors.textTertiary,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  state.error!,
                                  style: AppText.caption.copyWith(color: Colors.white70),
                                  textAlign: TextAlign.center,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 8),
                                TextButton(
                                  onPressed: () => _c.openEpisode(state.currentIndex),
                                  child: Text(
                                    'Try again',
                                    style: AppText.caption.copyWith(color: AppColors.accent),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Container(color: Colors.black),
                        Video(controller: _c.videoController, controls: NoVideoControls),
                        // Double-tap the sides for ±10s, via the same seekBy the
                        // fullscreen player uses (room-viewer guard + broadcast).
                        Row(children: [
                          Expanded(child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _bumpControls,
                            onDoubleTap: () => _c.seekBy(const Duration(seconds: -10)),
                          )),
                          Expanded(child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _bumpControls,
                            onDoubleTap: () => _c.seekBy(const Duration(seconds: 10)),
                          )),
                        ]),
                        if (_showControls)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: WatchMiniControls(
                              playing: _playing,
                              position: _pos,
                              duration: _c.player.state.duration,
                              onPlayPause: () { _c.togglePlay(); _bumpControls(); },
                              onPrevious: _c.state.currentIndex > 0
                                  ? () => _c.openEpisode(_c.state.currentIndex - 1)
                                  : null,
                              onNext: _c.state.currentIndex < episodes.length - 1
                                  ? () => _c.openEpisode(_c.state.currentIndex + 1)
                                  : null,
                              onSeek: (d) { _c.seekTo(d); _bumpControls(); },
                              // Suspend the auto-hide for the whole drag (not
                              // just a per-tick bump) — a thumb held still has
                              // no onChanged ticks to keep pushing the timer
                              // back, so without this the controls could hide
                              // mid-drag and drop the pending seek. onSeek
                              // above resumes it once the drag commits.
                              onScrubStart: () => _hide?.cancel(),
                              onFullscreen: _goFullscreen,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              TabBar(
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.textTertiary,
                indicatorColor: AppColors.accent,
                labelStyle: AppText.body,
                tabs: [
                  if (multi) const Tab(text: 'Episodes'),
                  const Tab(text: 'Comments'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    if (multi) _episodeList(episodes),
                    const WatchCommentsPlaceholder(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _episodeList(List<Episode> episodes) => ListView.builder(
        itemCount: episodes.length,
        itemBuilder: (context, i) {
          final e = episodes[i];
          return ListTile(
            title: Text(e.title.isEmpty ? 'Episode ${i + 1}' : e.title,
                style: AppText.body),
            onTap: () => _c.openEpisode(i),
          );
        },
      );
}
