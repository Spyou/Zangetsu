import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/playback/my_list.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';

/// My List tab — shows a 3-column grid of saved titles.
///
/// Refreshes after returning from [DetailScreen] so toggling a title off
/// is reflected immediately.
class MyListScreen extends StatefulWidget {
  const MyListScreen({super.key});

  @override
  State<MyListScreen> createState() => _MyListScreenState();
}

class _MyListScreenState extends State<MyListScreen> {
  final _myList = sl<MyListStore>();

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // cellWidth: (screenWidth - 32px outer padding - 24px for 2 gaps) / 3
    final cellW = (mq.size.width - 32 - 24) / 3;
    final items = _myList.all();

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: const Text('My List', style: AppText.largeTitle),
            ),

            // ── Body ────────────────────────────────────────────────────────
            Expanded(
              child: items.isEmpty
                  ? const EmptyState(
                      icon: Icons.bookmark_outline,
                      message: 'Titles you save appear here',
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
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
                          ).then((_) {
                            if (mounted) setState(() {});
                          }),
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
