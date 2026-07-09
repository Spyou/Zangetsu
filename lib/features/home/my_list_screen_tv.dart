import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/models/media_item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../detail/detail_screen.dart';
import 'cubit/my_list_cubit.dart';

/// TV My List: a full-screen focusable poster grid backed by [MyListCubit].
///
/// Reuses the phone's cubit/state and [PosterCard] widget unchanged. Only the
/// interaction model changes: each card is wrapped in [TvFocusable] so the
/// D-pad navigates the grid and OK opens the Detail screen — matching the phone
/// tap behaviour. The rail↔content focus bridge in [RootShellTv] already
/// handles LEFT-at-edge → rail, so no additional navigation plumbing is needed.
///
/// The phone [MyListScreen] is byte-identical except for the single
/// `if (sl<AppMode>().isTv) return const MyListScreenTv();` branch added at
/// the top of [_MyListViewState.build].
class MyListScreenTv extends StatelessWidget {
  const MyListScreenTv({super.key});

  /// 5 columns matches a typical 1080 p TV at ~140 dp card width + margins.
  static const int _crossAxisCount = 5;
  static const double _cardWidth = 140;

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
                      childAspectRatio: 0.62,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 20,
                    ),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final entry = entries[i];
                      return TvFocusable(
                        autofocus: i == 0,
                        onTap: () => _openItem(context, entry.item),
                        focusLabel: entry.item.title,
                        child: PosterCard(
                          title: entry.item.title,
                          imageUrl: entry.item.cover,
                          headers: entry.item.coverHeaders,
                          cellWidth: _cardWidth,
                          showTitle: false,
                          // Touch gestures are disabled on TV; [TvFocusable]
                          // handles OK-key selection.
                          onTap: null,
                          onLongPress: null,
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
