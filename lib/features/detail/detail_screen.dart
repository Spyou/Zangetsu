import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/episode.dart';
import '../../core/models/media_detail.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/resume_store.dart';
import '../../core/repository/source_repository.dart';
import '../player/player_screen.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({super.key, required this.item});
  final MediaItem item;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  final _repo = sl<SourceRepository>();
  Future<MediaDetail>? _detail;

  @override
  void initState() {
    super.initState();
    _detail = _repo.detail(widget.item.url);
  }

  void _openPlayer(List<Episode> episodes, int index) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        sourceId: widget.item.sourceId,
        episodes: episodes,
        startIndex: index,
        resume: sl<ResumeStore>(),
        resolveSources: _repo.sources,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.item.title)),
      body: FutureBuilder<MediaDetail>(
        future: _detail,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Failed to load: ${snap.error}'));
          }
          final detail = snap.data!;
          final eps = detail.episodes;
          return ListView.builder(
            itemCount: eps.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(detail.title, style: Theme.of(context).textTheme.titleLarge),
                      if ((detail.description ?? '').isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(detail.description!, maxLines: 4, overflow: TextOverflow.ellipsis),
                      ],
                      const SizedBox(height: 8),
                      Text('${eps.length} episodes',
                          style: Theme.of(context).textTheme.labelMedium),
                      const Divider(),
                    ],
                  ),
                );
              }
              final ep = eps[i - 1];
              return ListTile(
                title: Text(ep.title),
                trailing: const Icon(Icons.play_arrow),
                onTap: () => _openPlayer(eps, i - 1),
              );
            },
          );
        },
      ),
    );
  }
}
