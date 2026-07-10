import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/schedule/schedule_models.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/poster_card.dart';
import 'schedule_cubit.dart';
import 'schedule_screen.dart' show openTitle;

// ponytail: two 3-line formatters duplicated from schedule_screen to avoid
// re-touching the committed phone file.
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

/// TV Schedule: D-pad UI mirroring `home_screen_tv.dart`'s `_TvRail` — focusable
/// top chips (Airing / Coming Soon), a focusable day-chip row, and a horizontal
/// card row of the selected day's airing entries (or the coming-soon list).
class ScheduleScreenTv extends StatefulWidget {
  const ScheduleScreenTv({super.key});

  @override
  State<ScheduleScreenTv> createState() => _ScheduleScreenTvState();
}

class _ScheduleScreenTvState extends State<ScheduleScreenTv> {
  int _tab = 0; // 0 = Airing, 1 = Coming Soon
  late final DateTime _today;
  late DateTime _selectedDay;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _selectedDay = _today;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ScheduleCubit>().state;
    final days = [for (var i = 0; i < 7; i++) _today.add(Duration(days: i))];

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Text('Schedule', style: AppText.title),
            ),
            const SizedBox(height: 16),
            // Top chips: Airing | Coming Soon
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Row(
                children: [
                  TvFocusable(
                    autofocus: true,
                    onTap: () => setState(() => _tab = 0),
                    child: _Chip(label: 'Airing', selected: _tab == 0),
                  ),
                  const SizedBox(width: 12),
                  TvFocusable(
                    onTap: () => setState(() => _tab = 1),
                    child: _Chip(label: 'Coming Soon', selected: _tab == 1),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_tab == 0) ...[
              _DayChipRow(
                days: days,
                selectedDay: _selectedDay,
                onSelect: (d) => setState(() => _selectedDay = d),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: state.loadingAiring
                    ? const Center(
                        child: CircularProgressIndicator(color: AppColors.accent))
                    : _AiringList(
                        entries: state.airingByDay[_selectedDay] ??
                            const <AiringEntry>[],
                      ),
              ),
            ] else
              Expanded(
                child: state.loadingSoon
                    ? const Center(
                        child: CircularProgressIndicator(color: AppColors.accent))
                    : _ComingSoonList(entries: state.comingSoon),
              ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected});
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.surface2,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: AppText.headline.copyWith(
            color: AppColors.textPrimary,
            fontSize: 15,
          ),
        ),
      );
}

class _DayChipRow extends StatelessWidget {
  const _DayChipRow({
    required this.days,
    required this.selectedDay,
    required this.onSelect,
  });
  final List<DateTime> days;
  final DateTime selectedDay;
  final ValueChanged<DateTime> onSelect;

  static const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(horizontal: 40),
        itemCount: days.length,
        itemBuilder: (context, i) {
          final d = days[i];
          final selected = d == selectedDay;
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TvFocusable(
              onTap: () => onSelect(d),
              child: _Chip(
                label: i == 0 ? 'Today' : '${_wd[d.weekday - 1]} ${d.day}',
                selected: selected,
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Airing card row ─────────────────────────────────────────────────────────

class _AiringList extends StatelessWidget {
  const _AiringList({required this.entries});
  final List<AiringEntry> entries;

  static const double _cardWidth = 140;
  static const double _cardHeight = 210;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Text('Nothing airing on this day.', style: AppText.caption),
      );
    }
    final now = DateTime.now();
    return SizedBox(
      height: _cardHeight + 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(horizontal: 40),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: SizedBox(
                width: _cardWidth,
                child: TvFocusable(
                  autofocus: index == 0,
                  onTap: () => openTitle(context, entry.title),
                  child: SizedBox(
                    width: _cardWidth,
                    height: _cardHeight,
                    child: Stack(
                      children: [
                        PosterCard(
                          title: entry.title,
                          imageUrl: entry.coverUrl,
                          cellWidth: _cardWidth,
                          showTitle: false,
                          onTap: null,
                          onLongPress: null,
                        ),
                        Positioned(
                          left: 6,
                          right: 6,
                          top: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _countdown(entry.airsAtLocal, now),
                              style: AppText.caption
                                  .copyWith(color: AppColors.accent, fontSize: 11),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 6,
                          right: 6,
                          bottom: 6,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                entry.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  shadows: const [
                                    Shadow(color: Colors.black, blurRadius: 4),
                                  ],
                                ),
                              ),
                              Text(
                                'Ep ${entry.episode} · ${_fmtTime(entry.airsAtLocal)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption.copyWith(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  shadows: const [
                                    Shadow(color: Colors.black, blurRadius: 4),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Coming-soon card row ────────────────────────────────────────────────────

class _ComingSoonList extends StatelessWidget {
  const _ComingSoonList({required this.entries});
  final List<ComingSoonEntry> entries;

  static const double _cardWidth = 140;
  static const double _cardHeight = 210;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Text("Couldn't load coming soon — pull to refresh.",
            style: AppText.caption),
      );
    }
    return SizedBox(
      height: _cardHeight + 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(horizontal: 40),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: SizedBox(
                width: _cardWidth,
                child: TvFocusable(
                  autofocus: index == 0,
                  onTap: () => openTitle(context, entry.title),
                  focusLabel: entry.title,
                  child: SizedBox(
                    width: _cardWidth,
                    height: _cardHeight,
                    child: PosterCard(
                      title: entry.title,
                      imageUrl: entry.posterUrl,
                      cellWidth: _cardWidth,
                      showTitle: false,
                      onTap: null,
                      onLongPress: null,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
