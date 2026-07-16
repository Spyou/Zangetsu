import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/schedule/schedule_models.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import 'schedule_cubit.dart';
import 'schedule_screen.dart' show openTitle;

// ponytail: three small formatters kept TV-local so the redesign doesn't
// re-touch schedule_screen's exports.
String _fmtTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}

({String text, Color bg, Color fg})? _airPill(DateTime airs, DateTime now) {
  final diff = airs.difference(now);
  if (diff.isNegative) return (text: 'Aired', bg: Colors.black54, fg: AppColors.textSecondary);
  if (diff.inMinutes < 60) return (text: 'Soon', bg: AppColors.accent, fg: Colors.white);
  if (diff.inHours < 24) return (text: 'in ${diff.inHours}h', bg: Colors.black54, fg: Colors.white);
  return (text: 'in ${diff.inDays}d', bg: Colors.black54, fg: Colors.white);
}

const _monShort = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
String _monthDay(DateTime d) => '${_monShort[d.month - 1]} ${d.day}, ${d.year}';

/// TV Schedule: D-pad "New & Hot" — focusable top chips (Anime / Movies & TV /
/// My List), a day-chip row for the anime tabs, and a horizontal rail of big
/// landscape cards. Mirrors `home_screen_tv.dart`'s focus pattern.
class ScheduleScreenTv extends StatefulWidget {
  const ScheduleScreenTv({super.key});

  @override
  State<ScheduleScreenTv> createState() => _ScheduleScreenTvState();
}

class _ScheduleScreenTvState extends State<ScheduleScreenTv> {
  int _tab = 0; // 0 = Anime, 1 = Movies & TV, 2 = My List
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
    final showDays = _tab != 1; // anime + my-list use the day picker

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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Row(
                children: [
                  TvFocusable(
                    autofocus: true,
                    onTap: () => setState(() => _tab = 0),
                    child: _Chip(label: 'Anime', selected: _tab == 0),
                  ),
                  const SizedBox(width: 12),
                  TvFocusable(
                    onTap: () => setState(() => _tab = 1),
                    child: _Chip(label: 'Movies & TV', selected: _tab == 1),
                  ),
                  const SizedBox(width: 12),
                  TvFocusable(
                    onTap: () => setState(() => _tab = 2),
                    child: _Chip(label: 'My List', selected: _tab == 2),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (showDays) ...[
              _DayChipRow(
                days: days,
                selectedDay: _selectedDay,
                onSelect: (d) => setState(() => _selectedDay = d),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(child: _body(state)),
          ],
        ),
      ),
    );
  }

  Widget _body(ScheduleState state) {
    if (_tab == 1) {
      return state.loadingSoon
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : _MoviesRail(entries: state.comingSoon);
    }
    final byDay = _tab == 2 ? state.myListByDay : state.airingByDay;
    return state.loadingAiring
        ? Center(child: CircularProgressIndicator(color: AppColors.accent))
        : _AiringRail(
            entries: byDay[_selectedDay] ?? const <AiringEntry>[],
            emptyMessage: _tab == 2
                ? 'None of the anime you follow air on this day.'
                : 'Nothing airing on this day.',
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
          style: AppText.headline.copyWith(color: AppColors.textPrimary, fontSize: 15),
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

// ── rails ────────────────────────────────────────────────────────────────────

class _AiringRail extends StatelessWidget {
  const _AiringRail({required this.entries, required this.emptyMessage});
  final List<AiringEntry> entries;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(child: Text(emptyMessage, style: AppText.caption));
    }
    final now = DateTime.now();
    return _Rail(
      count: entries.length,
      builder: (context, i) {
        final e = entries[i];
        return _PosterTile(
          title: e.title,
          imageUrl: e.coverUrl,
          subtitle: 'Ep ${e.episode} · ${_fmtTime(e.airsAtLocal)}',
          pill: _airPill(e.airsAtLocal, now),
          onTap: () => openTitle(context, e.title),
        );
      },
    );
  }
}

class _MoviesRail extends StatelessWidget {
  const _MoviesRail({required this.entries});
  final List<ComingSoonEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Text("Couldn't load coming soon — pull to refresh.",
            style: AppText.caption),
      );
    }
    return _Rail(
      count: entries.length,
      builder: (context, i) {
        final e = entries[i];
        final date = e.releaseDate != null ? ' · ${_monthDay(e.releaseDate!)}' : '';
        return _PosterTile(
          title: e.title,
          imageUrl: e.posterUrl,
          subtitle: '${e.isTv ? 'Series' : 'Movie'}$date',
          pill: null,
          onTap: () => openTitle(context, e.title),
        );
      },
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({required this.count, required this.builder});
  final int count;
  final Widget Function(BuildContext, int) builder;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _PosterTile.cardHeight + 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 8),
        itemCount: count,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(right: 16),
          child: builder(context, i),
        ),
      ),
    );
  }
}

/// Compact 2:3 poster tile: small cover, status pill overlay, title + subtitle
/// beneath. Focusable for D-pad.
class _PosterTile extends StatelessWidget {
  const _PosterTile({
    required this.title,
    required this.imageUrl,
    required this.subtitle,
    required this.pill,
    required this.onTap,
  });
  final String title;
  final String? imageUrl;
  final String subtitle;
  final ({String text, Color bg, Color fg})? pill;
  final VoidCallback onTap;

  static const double cardWidth = 134;
  static const double imageHeight = 190; // ~2:3
  static const double cardHeight = imageHeight + 56; // + title (2 lines) + subtitle

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: cardWidth,
      child: TvFocusable(
        onTap: onTap,
        focusLabel: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: cardWidth,
                height: imageHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppColors.surface2, AppColors.surface],
                        ),
                      ),
                    ),
                    if (imageUrl != null)
                      Image.network(imageUrl!, fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox.shrink()),
                    if (pill != null)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: pill!.bg,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(pill!.text,
                              style: AppText.caption.copyWith(
                                  color: pill!.fg,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 10.5)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(
                    color: AppColors.textPrimary, fontWeight: FontWeight.w600, height: 1.2)),
            const SizedBox(height: 2),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
