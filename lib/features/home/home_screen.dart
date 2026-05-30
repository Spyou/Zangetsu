import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/repository/source_repository.dart';
import '../detail/detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _repo = sl<SourceRepository>();
  final _controller = TextEditingController();
  Future<List<MediaItem>>? _results;

  void _search(String q) {
    if (q.trim().isEmpty) return;
    setState(() => _results = _repo.search(q.trim()));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          onSubmitted: _search,
          decoration: const InputDecoration(
            hintText: 'Search $kAppName…',
            border: InputBorder.none,
          ),
        ),
        actions: [IconButton(icon: const Icon(Icons.search), onPressed: () => _search(_controller.text))],
      ),
      body: _results == null
          ? const Center(child: Text('Search for an anime to start.'))
          : FutureBuilder<List<MediaItem>>(
              future: _results,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Search failed: ${snap.error}'));
                }
                final items = snap.data ?? const [];
                if (items.isEmpty) return const Center(child: Text('No results.'));
                return GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3, childAspectRatio: 0.62,
                    crossAxisSpacing: 8, mainAxisSpacing: 8),
                  itemCount: items.length,
                  itemBuilder: (context, i) => _PosterCard(item: items[i]),
                );
              },
            ),
    );
  }
}

class _PosterCard extends StatelessWidget {
  const _PosterCard({required this.item});
  final MediaItem item;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => DetailScreen(item: item))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: item.cover == null
                  ? const ColoredBox(color: Colors.black26)
                  : CachedNetworkImage(
                      imageUrl: item.cover!,
                      httpHeaders: item.coverHeaders,
                      fit: BoxFit.cover, width: double.infinity,
                      errorWidget: (_, __, ___) => const ColoredBox(color: Colors.black26),
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
