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
import 'watch_comments_placeholder.dart';

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
  }

  /// Empty list = let Android's own auto-rotate setting decide. That's how we
  /// get "sensor only when auto-rotate is on" without reading the setting.
  void allowRotation() => SystemChrome.setPreferredOrientations(const []);

  @override
  void dispose() {
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
