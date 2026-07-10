import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/playback/my_list.dart';
import '../../core/schedule/airing_service.dart';
import '../../core/schedule/coming_soon_service.dart';
import '../../core/schedule/schedule_models.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../home/search_screen.dart';
import 'schedule_cubit.dart';
import 'schedule_screen_tv.dart';

/// The Schedule tab: anime airing calendar + movie/TV coming-soon. Self-contained
/// (creates its own ScheduleCubit) so it can sit directly in the shell page list.
class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => ScheduleCubit(
        sl<AiringService>(),
        sl<ComingSoonService>(),
        sl<MyListStore>(),
      )..load(),
      child: sl<AppMode>().isTv ? const ScheduleScreenTv() : const ScheduleBody(),
    );
  }
}

/// Search the user's sources for [title] so they can watch + subscribe. Reuses
/// the normal search flow (across all their source ecosystems) — the schedule
/// itself is metadata with no source/url of its own.
void openTitle(BuildContext context, String title) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => SearchScreen(initialQuery: title)),
  );
}

String _fmtTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}

String _countdown(DateTime airsAtLocal, DateTime now) {
  final diff = airsAtLocal.difference(now);
  if (diff.isNegative) return 'Aired';
  if (diff.inMinutes < 60) return 'in ${diff.inMinutes}m';
  if (diff.inHours < 24) return 'in ${diff.inHours}h';
  return 'in ${diff.inDays}d';
}

class ScheduleBody extends StatelessWidget {
  const ScheduleBody({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text('Schedule', style: AppText.title),
          bottom: TabBar(
            indicatorColor: AppColors.accent,
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            labelStyle: AppText.headline,
            unselectedLabelStyle: AppText.headline,
            dividerHeight: 0,
            tabs: const [Tab(text: 'Airing'), Tab(text: 'Coming Soon')],
          ),
        ),
        body: BlocBuilder<ScheduleCubit, ScheduleState>(
          builder: (context, state) => TabBarView(
            children: [_AiringTab(state: state), _ComingSoonTab(state: state)],
          ),
        ),
      ),
    );
  }
}

class _AiringTab extends StatefulWidget {
  const _AiringTab({required this.state});
  final ScheduleState state;
  @override
  State<_AiringTab> createState() => _AiringTabState();
}

class _AiringTabState extends State<_AiringTab> {
  late DateTime _selectedDay;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDay = DateTime(now.year, now.month, now.day);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    if (s.loadingAiring) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    // 7 day columns starting today.
    final today = DateTime.now();
    final days = [for (var i = 0; i < 7; i++) DateTime(today.year, today.month, today.day).add(Duration(days: i))];
    final list = s.airingByDay[_selectedDay] ?? const <AiringEntry>[];
    final now = DateTime.now();
    return Column(
      children: [
        // Filter chips
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Wrap(spacing: 8, children: [
              _FilterChip(label: 'All', selected: s.filter == ScheduleFilter.all,
                  onTap: () => context.read<ScheduleCubit>().setFilter(ScheduleFilter.all)),
              _FilterChip(label: 'My List', selected: s.filter == ScheduleFilter.myList,
                  onTap: () => context.read<ScheduleCubit>().setFilter(ScheduleFilter.myList)),
            ]),
          ),
        ),
        // Day selector
        SizedBox(
          height: 64,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: days.length,
            itemBuilder: (_, i) {
              final d = days[i];
              final isToday = i == 0;
              final selected = d == _selectedDay;
              const wd = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: ChoiceChip(
                  selected: selected,
                  onSelected: (_) => setState(() => _selectedDay = d),
                  label: Text(isToday ? 'Today' : '${wd[d.weekday - 1]} ${d.day}'),
                  selectedColor: AppColors.accent,
                ),
              );
            },
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? Center(child: Text(
                  s.filter == ScheduleFilter.myList
                      ? 'None of your saved anime air on this day.'
                      : 'Nothing airing on this day.',
                  style: AppText.caption))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: list.length,
                  itemBuilder: (_, i) => _AiringRow(entry: list[i], now: now),
                ),
        ),
      ],
    );
  }
}

class _AiringRow extends StatelessWidget {
  const _AiringRow({required this.entry, required this.now});
  final AiringEntry entry;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openTitle(context, entry.title),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: entry.coverUrl != null
                  ? Image.network(entry.coverUrl!, width: 48, height: 68, fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 68))
                  : const SizedBox(width: 48, height: 68),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(entry.title, style: AppText.headline, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Text('Ep ${entry.episode} · ${_fmtTime(entry.airsAtLocal)}', style: AppText.caption),
              ]),
            ),
            const SizedBox(width: 8),
            Text(_countdown(entry.airsAtLocal, now),
                style: AppText.caption.copyWith(color: AppColors.accent)),
          ]),
        ),
      ),
    );
  }
}

class _ComingSoonTab extends StatelessWidget {
  const _ComingSoonTab({required this.state});
  final ScheduleState state;
  @override
  Widget build(BuildContext context) {
    if (state.loadingSoon) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (state.comingSoon.isEmpty) {
      return Center(child: Text("Couldn't load coming soon — pull to refresh.",
          style: AppText.caption));
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: state.comingSoon.length,
      itemBuilder: (_, i) {
        final e = state.comingSoon[i];
        return Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => openTitle(context, e.title),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: e.posterUrl != null
                      ? Image.network(e.posterUrl!, width: 48, height: 68, fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 68))
                      : const SizedBox(width: 48, height: 68),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.title, style: AppText.headline, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text('${e.isTv ? 'TV' : 'Movie'}${e.releaseDate != null ? ' · ${e.releaseDate!.year}-${e.releaseDate!.month.toString().padLeft(2, '0')}-${e.releaseDate!.day.toString().padLeft(2, '0')}' : ''}',
                      style: AppText.caption),
                ])),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: AppColors.accent,
      );
}
