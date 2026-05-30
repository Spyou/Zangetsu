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
    final p = sl<ProviderManager>().get('allanime')!;
    final buf = StringBuffer();
    try {
      final info = await p.getInfo();
      buf.writeln('provider: ${info.name} (${info.type.name})');

      final List<MediaItem> results = await p.search('one piece', 1);
      buf.writeln('search("one piece") -> ${results.length} result(s); '
          'first=${results.isEmpty ? "—" : results.first.title}');

      final MediaDetail detail = await p.getDetail(results.first.url);
      final List<Episode> eps = await p.getEpisodes(detail.url);
      buf.writeln('detail: ${detail.title} • ${eps.length} eps '
          '(${eps.take(3).map((e) => e.number).join(", ")}…)');

      final Episode ep1 =
          eps.firstWhere((e) => e.number == 1, orElse: () => eps.first);
      buf.writeln('resolving sources for ep ${ep1.number} '
          '(AES decrypt on-device, may take ~30s)…');
      setState(() => _log = buf.toString());

      final List<VideoSource> sources = await p.getVideoSources(ep1.url);
      final s = sources.first;
      buf.writeln('sources for "${eps.first.title}": ${sources.length} • '
          'first=${s.quality}/${s.container.name}/${s.kind.name} '
          'url=${s.url} subs=${s.subtitles.length} '
          'referer=${s.headers?['Referer']}');
      buf.writeln('\n✅ SLICE OK');
    } catch (e, st) {
      buf.writeln('\n❌ SLICE FAILED: $e');
      // ignore: avoid_print
      print('### DEVSLICE FAILED: $e\n$st');
    }
    // ignore: avoid_print
    print('### DEVSLICE LOG:\n${buf.toString()}');
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
