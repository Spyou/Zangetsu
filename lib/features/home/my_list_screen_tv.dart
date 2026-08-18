import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_poster_tile.dart';
import '../../core/ui/list_status_sheet.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';
import 'cubit/my_list_cubit.dart';

/// TV My List: a full-screen focusable poster grid backed by [MyListCubit].
///
/// Reuses the phone's cubit/state and [PosterCard] widget unchanged. Only the
/// interaction model changes: each card is wrapped in [TvFocusable] so the
/// D-pad navigates the grid, OK opens the Detail screen, and a held OK opens
/// the same status/remove sheet as the phone long-press. The rail↔content
/// focus bridge in [RootShellTv] already handles LEFT-at-edge → rail, so no
/// additional navigation plumbing is needed.
///
/// The phone [MyListScreen] is byte-identical except for the single
/// `if (sl<AppMode>().isTv) return const MyListScreenTv();` branch added at
/// the top of [_MyListViewState.build].
class MyListScreenTv extends StatelessWidget {
  const MyListScreenTv({super.key});

  /// 6 columns keeps the cards near the home-rail ~140 dp scale on a 1080p TV
  /// (matches the see-all grid; 5 rendered them oversized).
  static const int _crossAxisCount = 6;

  Future<void> _openItem(BuildContext context, MediaItem item) async {
    final cubit = context.read<MyListCubit>();
    await Navigator.push(context, DetailScreen.route(item));
    cubit.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Title header ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
              child: Text('My List', style: AppText.largeTitle),
            ),
            // ── Poster grid ───────────────────────────────────────────────────
            Expanded(
              child: BlocBuilder<MyListCubit, List<MyListEntry>>(
                builder: (context, entries) {
                  if (entries.isEmpty) {
                    return const EmptyState(
                      icon: Icons.bookmark_outline,
                      message: 'Titles you add appear here',
                    );
                  }
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(40, 0, 40, 40),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _crossAxisCount,
                      // Poster art + title below (outline hugs the art).
                      childAspectRatio: 0.56,
                      crossAxisSpacing: 18,
                      mainAxisSpacing: 22,
                    ),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final entry = entries[i];
                      return TvPosterTile(
                        autofocus: i == 0,
                        title: entry.item.title,
                        imageUrl: entry.item.cover,
                        headers: entry.item.coverHeaders,
                        onTap: () => _openItem(context, entry.item),
                        onLongPress: () {
                          final cubit = context.read<MyListCubit>();
                          showListStatusSheet(
                            context,
                            item: entry.item,
                            onChanged: cubit.reload,
                          );
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
