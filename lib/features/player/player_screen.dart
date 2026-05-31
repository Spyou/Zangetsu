import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/frosted_surface.dart';
import 'player_controller.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.sourceId,
    required this.episodes,
    required this.startIndex,
    required this.resume,
    required this.resolveSources,
  });

  final String sourceId;
  final List<Episode> episodes;
  final int startIndex;
  final ResumeStore resume;
  final Future<List<VideoSource>> Function(String episodeUrl) resolveSources;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlayerController _c;

  @override
  void initState() {
    super.initState();
    _c = PlayerController(
      sourceId: widget.sourceId,
      episodes: widget.episodes,
      resume: widget.resume,
      resolveSources: widget.resolveSources,
      dio: sl<Dio>(),
    )..init(widget.startIndex);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _openPicker() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: false,
      backgroundColor: Colors.transparent,
      builder: (_) {
        final kinds = availableKinds(_c.sources);
        return FrostedSurface(
          blur: true,
          opacity: 0.75,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Grab handle
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: const SizedBox(width: 36, height: 4),
                  ),
                ),
                ListView(
                  shrinkWrap: true,
                  children: [
                    if (_c.qualities.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
                        child: Text('Quality', style: AppText.headline),
                      ),
                      ListTile(
                        dense: true,
                        leading: _c.activeQuality == null
                            ? const Icon(Icons.check,
                                color: AppColors.accent, size: 20)
                            : const SizedBox(width: 20),
                        title: Text('Auto',
                            style: AppText.body
                                .copyWith(color: AppColors.textPrimary)),
                        onTap: () {
                          Navigator.pop(context);
                          _c.selectQuality(null);
                        },
                      ),
                      for (final v in _c.qualities)
                        ListTile(
                          dense: true,
                          leading: _c.activeQuality?.url == v.url
                              ? const Icon(Icons.check,
                                  color: AppColors.accent, size: 20)
                              : const SizedBox(width: 20),
                          title: Text(v.quality,
                              style: AppText.body
                                  .copyWith(color: AppColors.textPrimary)),
                          onTap: () {
                            Navigator.pop(context);
                            _c.selectQuality(v);
                          },
                        ),
                      const Divider(color: AppColors.hairline),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 4, 20, 4),
                        child: Text('Source', style: AppText.headline),
                      ),
                    ],
                    for (final k in kinds)
                      for (final s
                          in sortByQuality(sourcesForKind(_c.sources, k)))
                        ListTile(
                          dense: true,
                          leading: s == _c.active
                              ? const Icon(Icons.check,
                                  color: AppColors.accent, size: 20)
                              : const SizedBox(width: 20),
                          title: Text(
                            '${k.name.toUpperCase()} • '
                            '${s.quality?.isNotEmpty == true ? s.quality : s.container.name}',
                            style: AppText.body
                                .copyWith(color: AppColors.textPrimary),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            _c.switchSource(s);
                          },
                        ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          if (_c.error != null) {
            return _Centered(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 40,
                      color: AppColors.textTertiary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _c.error!,
                      style: AppText.body,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          if (_c.loadingSources) {
            return const _Centered(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CupertinoActivityIndicator(color: Colors.white, radius: 14),
                  SizedBox(height: 12),
                  Text('Resolving sources…', style: AppText.body),
                ],
              ),
            );
          }
          return Column(
            children: [
              Expanded(child: Video(controller: _c.videoController)),
              // Control bar — sits on solid black (letterbox); no BackdropFilter here.
              DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border(
                    top: BorderSide(color: AppColors.hairline, width: 0.5),
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Ep ${_c.currentEpisode.number ?? ''} • '
                            '${_c.active?.kind.name ?? ''} '
                            '${_c.activeQuality?.quality ?? _c.active?.quality ?? ''}',
                            style: AppText.caption
                                .copyWith(color: AppColors.textSecondary),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.high_quality,
                              color: Colors.white),
                          onPressed:
                              _c.sources.isEmpty ? null : _openPicker,
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next,
                              color: Colors.white),
                          onPressed: _c.playNext,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: Center(child: child),
      );
}
