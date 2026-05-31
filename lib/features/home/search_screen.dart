import 'package:flutter/material.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';

/// Dedicated search screen pushed from the Home header search icon.
///
/// Preserves the exact search behavior from the original [HomeScreen]:
/// block-body [setState] that assigns the [Future] (not arrow-body),
/// controller [dispose], results grid with [SkeletonGrid]/[EmptyState]/
/// 3-col [PosterCard] [GridView].
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _repo = sl<SourceRepository>();
  final _controller = TextEditingController();
  Future<List<MediaItem>>? _results;

  void _search(String q) {
    if (q.trim().isEmpty) return;
    // Block-body setState: the closure must return void. An arrow body here
    // would return the Future from the assignment, which setState forbids.
    setState(() {
      _results = _repo.search(q.trim());
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // cellWidth = (screenWidth - 40 px screen padding - 24 px for 2 gaps) / 3
    final cellW = (mq.size.width - 40 - 24) / 3;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row: back arrow + search field ──────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.arrow_back_ios_new,
                      color: Colors.white,
                      size: 20,
                    ),
                    onPressed: () => Navigator.pop(context),
                    tooltip: 'Back',
                  ),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          const Icon(
                            Icons.search,
                            size: 20,
                            color: AppColors.textTertiary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              autofocus: true,
                              textInputAction: TextInputAction.search,
                              onSubmitted: _search,
                              style: AppText.body
                                  .copyWith(color: AppColors.textPrimary),
                              cursorColor: AppColors.accent,
                              decoration: InputDecoration(
                                hintText: 'Search $kAppName…',
                                hintStyle: AppText.body,
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                    vertical: 14),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // ── Results area ────────────────────────────────────────────────
            Expanded(
              child: _results == null
                  ? const EmptyState(
                      icon: Icons.movie_filter_outlined,
                      message: 'Search for something to watch',
                    )
                  : FutureBuilder<List<MediaItem>>(
                      future: _results,
                      builder: (context, snap) {
                        if (snap.connectionState == ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.all(20),
                            child: SkeletonGrid(),
                          );
                        }
                        if (snap.hasError) {
                          return const EmptyState(
                            icon: Icons.error_outline,
                            message:
                                'Search failed. Pull to retry or try another title.',
                          );
                        }
                        final items = snap.data ?? const [];
                        if (items.isEmpty) {
                          return const EmptyState(
                            icon: Icons.search_off,
                            message: 'No results for that title',
                          );
                        }
                        return GridView.builder(
                          padding: const EdgeInsets.all(20),
                          cacheExtent: 800,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 0.62,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 16,
                          ),
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final item = items[i];
                            return PosterCard(
                              title: item.title,
                              imageUrl: item.cover,
                              headers: item.coverHeaders,
                              cellWidth: cellW,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => DetailScreen(item: item),
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
    );
  }
}
