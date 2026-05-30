import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/video_source.dart';
import '../../core/playback/resume_store.dart';
import '../../core/playback/source_selection.dart';
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
      builder: (_) {
        final kinds = availableKinds(_c.sources);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              if (_c.qualities.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text('Quality', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                ListTile(
                  dense: true,
                  leading: Icon(_c.activeQuality == null ? Icons.check : null),
                  title: const Text('Auto'),
                  onTap: () { Navigator.pop(context); _c.selectQuality(null); },
                ),
                for (final v in _c.qualities)
                  ListTile(
                    dense: true,
                    leading: Icon(_c.activeQuality?.url == v.url ? Icons.check : null),
                    title: Text(v.quality),
                    onTap: () { Navigator.pop(context); _c.selectQuality(v); },
                  ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text('Source', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
              for (final k in kinds)
                for (final s in sortByQuality(sourcesForKind(_c.sources, k)))
                  ListTile(
                    dense: true,
                    leading: Icon(s == _c.active ? Icons.check : null),
                    title: Text('${k.name.toUpperCase()} • '
                        '${s.quality?.isNotEmpty == true ? s.quality : s.container.name}'),
                    onTap: () {
                      Navigator.pop(context);
                      _c.switchSource(s);
                    },
                  ),
            ],
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
            return _Centered(child: Text(_c.error!, style: const TextStyle(color: Colors.white)));
          }
          if (_c.loadingSources) {
            return const _Centered(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Resolving sources…', style: TextStyle(color: Colors.white70)),
              ]),
            );
          }
          return SafeArea(
            child: Column(
              children: [
                Expanded(child: Video(controller: _c.videoController)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Ep ${_c.currentEpisode.number ?? ''} • '
                            '${_c.active?.kind.name ?? ''} '
                            '${_c.activeQuality?.quality ?? _c.active?.quality ?? ''}',
                            style: const TextStyle(color: Colors.white70)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.high_quality, color: Colors.white),
                        onPressed: _c.sources.isEmpty ? null : _openPicker,
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next, color: Colors.white),
                        onPressed: _c.playNext,
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
