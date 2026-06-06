import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/buttons.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/states.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart';
import '../detail/detail_screen.dart';
import 'cubit/my_list_cubit.dart';

/// My List — one unified, status-organised library (the app's saved titles plus
/// AniList-imported rows), filterable by status and by type.
class MyListScreen extends StatelessWidget {
  const MyListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => MyListCubit(sl<MyListStore>(), sl<ListStatusStore>()),
      child: const _MyListView(),
    );
  }
}

class _MyListView extends StatefulWidget {
  const _MyListView();

  @override
  State<_MyListView> createState() => _MyListViewState();
}

class _MyListViewState extends State<_MyListView> {
  WatchStatus? _statusFilter; // null = All
  ProviderType? _typeFilter; // null = All

  Future<void> _openItem(BuildContext context, MediaItem item) async {
    final cubit = context.read<MyListCubit>();
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DetailScreen(item: item)),
    );
    cubit.reload();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cellW = (mq.size.width - 32 - 24) / 3;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('My List', style: AppText.largeTitle),
            ),
            Expanded(
              child: BlocBuilder<MyListCubit, List<MyListEntry>>(
                builder: (context, entries) {
                  if (entries.isEmpty) return _empty(context);

                  final hasAnime =
                      entries.any((e) => e.item.type == ProviderType.anime);
                  final hasMovies =
                      entries.any((e) => e.item.type != ProviderType.anime);
                  final presentStatuses = WatchStatus.values
                      .where((s) => entries.any((e) => e.status == s))
                      .toList();

                  final filtered = entries.where((e) {
                    if (_statusFilter != null && e.status != _statusFilter) {
                      return false;
                    }
                    if (_typeFilter != null && e.item.type != _typeFilter) {
                      return false;
                    }
                    return true;
                  }).toList();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _statusBar(presentStatuses),
                      if (hasAnime && hasMovies) _typeBar(),
                      const SizedBox(height: 4),
                      Expanded(
                        child: filtered.isEmpty
                            ? const EmptyState(
                                icon: Icons.filter_list_off_rounded,
                                message: 'Nothing here in this filter',
                              )
                            : GridView.builder(
                                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                                cacheExtent: 800,
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 3,
                                      childAspectRatio: 0.62,
                                      crossAxisSpacing: 12,
                                      mainAxisSpacing: 16,
                                    ),
                                itemCount: filtered.length,
                                itemBuilder: (context, i) {
                                  final entry = filtered[i];
                                  return PosterCard(
                                    title: entry.item.title,
                                    imageUrl: entry.item.cover,
                                    headers: entry.item.coverHeaders,
                                    cellWidth: cellW,
                                    onTap: () => _openItem(context, entry.item),
                                  );
                                },
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Filter bars ────────────────────────────────────────────────────────────

  Widget _statusBar(List<WatchStatus> present) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _chip('All', _statusFilter == null, () {
            setState(() => _statusFilter = null);
          }),
          for (final s in present)
            _chip(s.shortLabel, _statusFilter == s, () {
              setState(() => _statusFilter = s);
            }),
        ],
      ),
    );
  }

  Widget _typeBar() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _chip('All types', _typeFilter == null, () {
            setState(() => _typeFilter = null);
          }, small: true),
          _chip('Anime', _typeFilter == ProviderType.anime, () {
            setState(() => _typeFilter = ProviderType.anime);
          }, small: true),
          _chip('Movies', _typeFilter == ProviderType.movie, () {
            setState(() => _typeFilter = ProviderType.movie);
          }, small: true),
        ],
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap, {bool small = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: small ? 12 : 14, vertical: 7),
          decoration: BoxDecoration(
            color: active ? AppColors.accent : AppColors.surface,
            borderRadius: BorderRadius.circular(20),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppText.caption.copyWith(
              color: active ? Colors.white : AppColors.textSecondary,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              fontSize: small ? 12 : 13,
            ),
          ),
        ),
      ),
    );
  }

  // ── Empty / sign-in ──────────────────────────────────────────────────────
  Widget _empty(BuildContext context) {
    final auth = context.watch<AuthCubit>().state;
    if (!auth.isLoggedIn) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.bookmark_outline,
                size: 56,
                color: AppColors.textTertiary,
              ),
              const SizedBox(height: 16),
              Text(
                'Sign in to build your list',
                style: AppText.body,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 180,
                child: PrimaryButton(
                  label: 'Sign in',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return const EmptyState(
      icon: Icons.bookmark_outline,
      message: 'Titles you add appear here',
    );
  }
}
