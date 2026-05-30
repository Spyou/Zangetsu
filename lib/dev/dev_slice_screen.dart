import 'package:flutter/material.dart';

import '../core/di/injector.dart';
import '../core/models/episode.dart';
import '../core/models/media_detail.dart';
import '../core/models/media_item.dart';
import '../core/models/video_source.dart';
import '../core/provider/provider_manager.dart';

/// Throwaway screen that runs the full content-runtime slice against the
/// bundled example provider and prints the result. Replaced by real UI in P3+.
class DevSliceScreen extends StatefulWidget {
  const DevSliceScreen({super.key});
  @override
  State<DevSliceScreen> createState() => _DevSliceScreenState();
}

class _DevSliceScreenState extends State<DevSliceScreen> {
  String _log = 'Running slice…';

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final p = sl<ProviderManager>().get('example')!;
    final buf = StringBuffer();
    try {
      final info = await p.getInfo();
      buf.writeln('provider: ${info.name} (${info.type.name})');

      final List<MediaItem> results = await p.search('one', 1);
      buf.writeln('search("one") -> ${results.length} result(s): '
          '${results.map((r) => r.title).join(", ")}');

      final MediaDetail detail = await p.getDetail(results.first.url);
      buf.writeln('detail: ${detail.title} • ${detail.status.name} • '
          '${detail.episodes.length} eps • studios=${detail.studios.join(",")}');

      final List<Episode> eps = await p.getEpisodes(detail.url);
      buf.writeln('episodes: ${eps.map((e) => e.title).join(", ")}');

      final List<VideoSource> sources = await p.getVideoSources(eps.first.url);
      final s = sources.first;
      buf.writeln('sources for "${eps.first.title}": ${sources.length} • '
          'first=${s.quality}/${s.container.name}/${s.kind.name} '
          'url=${s.url} subs=${s.subtitles.length} '
          'referer=${s.headers?['Referer']}');
      buf.writeln('\n✅ SLICE OK');
    } catch (e) {
      buf.writeln('\n❌ SLICE FAILED: $e');
    }
    setState(() => _log = buf.toString());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('WATCH_APP dev slice')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Text(_log, style: const TextStyle(fontFamily: 'monospace')),
          ),
        ),
      );
}
