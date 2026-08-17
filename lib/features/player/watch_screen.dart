import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
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
    required this.episodes,
    required this.startIndex,
    required this.resume,
    required this.resolveSources,
    this.history,
    this.showTitle,
    this.cover,
    this.coverHeaders,
    this.showUrl,
    this.category,
    this.malId,
    this.scrobbleTitle,
    this.availableCategories = const [],
    this.resumePosition = Duration.zero,
  });

  final String sourceId;
  final List<Episode> episodes;
  final int startIndex;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;
  final WatchHistory? history;
  final String? showTitle;
  final String? cover;
  final Map<String, String>? coverHeaders;
  final String? showUrl;
  final String? category;
  final int? malId;
  final String? scrobbleTitle;
  final List<String> availableCategories;
  final Duration resumePosition;

  @override
  State<WatchScreen> createState() => WatchScreenState();
}

class WatchScreenState extends State<WatchScreen> {
  late final PlayerCubit _c;

  bool _showControls = true;
  Timer? _hide;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playSub;
  Duration _pos = Duration.zero;
  bool _playing = false;
  bool _inFullscreen = false;

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
    _c = PlayerCubit(
      sourceId: widget.sourceId,
      episodes: widget.episodes,
      resume: widget.resume,
      resolveSources: widget.resolveSources,
      dio: sl<Dio>(),
      history: widget.history,
      showTitle: widget.showTitle,
      cover: widget.cover,
      coverHeaders: widget.coverHeaders,
      showUrl: widget.showUrl,
      category: widget.category,
      malId: widget.malId,
      scrobbleTitle: widget.scrobbleTitle,
      availableCategories: widget.availableCategories,
      initialResume: widget.resumePosition,
    )..init(widget.startIndex);
    allowRotation();
    _posSub = _c.player.stream.position.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _playSub = _c.player.stream.playing.listen((p) {
      if (mounted) setState(() => _playing = p);
    });
    _bumpControls();
  }

  /// Empty list = let Android's own auto-rotate setting decide. That's how we
  /// get "sensor only when auto-rotate is on" without reading the setting.
  void allowRotation() => SystemChrome.setPreferredOrientations(const []);

  Future<void> _goFullscreen() async {
    if (_inFullscreen) return;
    _inFullscreen = true;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          cubit: _c,                       // hand over the running player
          sourceId: widget.sourceId,
          episodes: widget.episodes,
          startIndex: _c.state.currentIndex,
          resume: widget.resume,
          resolveSources: widget.resolveSources,
          history: widget.history,
          showTitle: widget.showTitle,
          cover: widget.cover,
          coverHeaders: widget.coverHeaders,
          showUrl: widget.showUrl,
          category: widget.category,
          malId: widget.malId,
          scrobbleTitle: widget.scrobbleTitle,
          availableCategories: widget.availableCategories,
        ),
      ),
    );
    _inFullscreen = false;
    // PlayerScreen's dispose pins portraitUp. Re-open rotation or turning the
    // phone will never work again for the rest of this session.
    if (mounted) allowRotation();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _posSub?.cancel();
    _playSub?.cancel();
    // We created it, so we close it. PlayerScreen never closes an injected one.
    _c.close();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  /// Exposed so the fullscreen route can hand the running cubit back.
  PlayerCubit get cubit => _c;

  @override
  Widget build(BuildContext context) {
    final multi = widget.episodes.length > 1;
    // Only fires when Android's auto-rotate is on — with it off, the app is
    // never handed a landscape constraint in the first place.
    if (MediaQuery.of(context).orientation == Orientation.landscape &&
        !_inFullscreen) {
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
                child: Stack(
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
                          onNext: _c.state.currentIndex < widget.episodes.length - 1
                              ? () => _c.openEpisode(_c.state.currentIndex + 1)
                              : null,
                          onSeek: (d) { _c.seekTo(d); _bumpControls(); },
                          onFullscreen: _goFullscreen,
                        ),
                      ),
                  ],
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
                    if (multi) _episodeList(),
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

  Widget _episodeList() => ListView.builder(
        itemCount: widget.episodes.length,
        itemBuilder: (context, i) {
          final e = widget.episodes[i];
          return ListTile(
            title: Text(e.title.isEmpty ? 'Episode ${i + 1}' : e.title,
                style: AppText.body),
            onTap: () => _c.openEpisode(i),
          );
        },
      );
}
