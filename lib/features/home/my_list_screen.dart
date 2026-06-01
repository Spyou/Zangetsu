import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/playback/my_list.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';
import 'cubit/my_list_cubit.dart';

/// My List tab — shows a 3-column grid of saved titles.
///
/// Wraps [_MyListView] in a [BlocProvider] so the cubit is scoped to this
/// route and disposes automatically when the screen is removed.
class MyListScreen extends StatelessWidget {
  const MyListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => MyListCubit(sl<MyListStore>()),
      child: const _MyListView(),
    );
  }
}

/// The actual UI, rebuilt by [BlocBuilder] whenever [MyListCubit] emits.
class _MyListView extends StatelessWidget {
  const _MyListView();

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // cellWidth: (screenWidth - 32px outer padding - 24px for 2 gaps) / 3
    final cellW = (mq.size.width - 32 - 24) / 3;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('My List', style: AppText.largeTitle),
            ),

            // ── Body ────────────────────────────────────────────────────────
            Expanded(
              child: BlocBuilder<MyListCubit, List<MediaItem>>(
                builder: (context, items) {
                  if (items.isEmpty) {
                    return const EmptyState(
                      icon: Icons.bookmark_outline,
                      message: 'Titles you save appear here',
                    );
                  }

                  return GridView.builder(
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
                        onTap: () {
                          final cubit = context.read<MyListCubit>();
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => DetailScreen(item: item),
                            ),
                          ).then((_) => cubit.reload());
                        },
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
