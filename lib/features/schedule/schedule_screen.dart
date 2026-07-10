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

/// The Schedule tab: a compact weekly airing calendar (anime) + upcoming
/// movies/TV. Self-contained (creates its own ScheduleCubit) so it can sit
/// directly in the shell page list.
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

/// Search the user's sources for [title] so they can watch + subscribe. The
/// schedule is metadata with no source/url of its own, so tapping a row routes
/// through the normal search flow (across every source ecosystem); from the
/// result's detail screen the user gets Play / Add to List / notify.
void openTitle(BuildContext context, String title) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => SearchScreen(initialQuery: title)),
  );
}

// ── formatting helpers ───────────────────────────────────────────────────────

const _wdShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _monShort = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const _monFull = ['January','February','March','April','May','June','July',
  'August','September','October','November','December'];

String _fmtTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}

String _monthYear(DateTime d) => '${_monFull[d.month - 1]} ${d.year}';
String _monthDay(DateTime d) => '${_monShort[d.month - 1]} ${d.day}, ${d.year}';

String _headerLabel(DateTime day, DateTime today) {
  if (day == today) return 'Today';
  if (day == today.add(const Duration(days: 1))) return 'Tomorrow';
  return '${_wdShort[day.weekday - 1]}, ${_monShort[day.month - 1]} ${day.day}';
}

/// Small over-row status pill for an anime episode.
({String text, Color bg, Color fg})? _airPill(DateTime airs, DateTime now) {
  final diff = airs.difference(now);
  if (diff.isNegative) return (text: 'Aired', bg: AppColors.surface2, fg: AppColors.textTertiary);
  if (diff.inMinutes < 60) return (text: 'in ${diff.inMinutes}m', bg: AppColors.accent, fg: Colors.white);
  if (diff.inHours < 24) return (text: 'in ${diff.inHours}h', bg: AppColors.surface2, fg: AppColors.textSecondary);
  return (text: 'in ${diff.inDays}d', bg: AppColors.surface2, fg: AppColors.textSecondary);
}

// ── screen body ──────────────────────────────────────────────────────────────

class ScheduleBody extends StatefulWidget {
  const ScheduleBody({super.key});
  @override
  State<ScheduleBody> createState() => _ScheduleBodyState();
}

class _ScheduleBodyState extends State<ScheduleBody> {
  late final DateTime _today;
  late DateTime _selectedDay;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _today = DateTime(now.year, now.month, now.day);
    _selectedDay = _today;
  }

  void _selectDay(DateTime d) => setState(() => _selectedDay = d);

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text('Schedule', style: AppText.title),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorColor: AppColors.accent,
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            labelStyle: AppText.headline,
            unselectedLabelStyle: AppText.headline,
            dividerHeight: 0,
            tabs: const [
              Tab(text: 'Anime'),
              Tab(text: 'Movies & TV'),
              Tab(text: 'My List'),
            ],
          ),
        ),
        body: BlocBuilder<ScheduleCubit, ScheduleState>(
          builder: (context, state) => TabBarView(
            children: [
              _DayView(
                byDay: state.airingByDay,
                loading: state.loadingAiring,
                today: _today,
                selectedDay: _selectedDay,
                onSelectDay: _selectDay,
                emptyMessage: 'Nothing airing on this day.',
              ),
              _MoviesView(state: state),
              _DayView(
                byDay: state.myListByDay,
                loading: state.loadingAiring,
                today: _today,
                selectedDay: _selectedDay,
                onSelectDay: _selectDay,
                emptyMessage: 'None of the anime you follow air on this day.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A weekly day picker + the compact airing list for the selected day.
class _DayView extends StatelessWidget {
  const _DayView({
    required this.byDay,
    required this.loading,
    required this.today,
    required this.selectedDay,
    required this.onSelectDay,
    required this.emptyMessage,
  });
  final Map<DateTime, List<AiringEntry>> byDay;
  final bool loading;
  final DateTime today;
  final DateTime selectedDay;
  final ValueChanged<DateTime> onSelectDay;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    final days = [for (var i = 0; i < 7; i++) today.add(Duration(days: i))];
    final list = byDay[selectedDay] ?? const <AiringEntry>[];
    final now = DateTime.now();
    return Column(
      children: [
        _WeekStrip(
          days: days,
          today: today,
          selectedDay: selectedDay,
          hasEntries: (d) => (byDay[d]?.isNotEmpty ?? false),
          onSelect: onSelectDay,
        ),
        _DayHeader(label: _headerLabel(selectedDay, today), count: list.length),
        Expanded(
          child: list.isEmpty
              ? _Empty(message: emptyMessage)
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const Divider(
                      height: 1, indent: 74, color: AppColors.hairline),
                  itemBuilder: (context, i) {
                    final e = list[i];
                    return _CompactRow(
                      title: e.title,
                      imageUrl: e.coverUrl,
                      subtitle: 'Ep ${e.episode} · ${_fmtTime(e.airsAtLocal)}',
                      pill: _airPill(e.airsAtLocal, now),
                      onTap: () => openTitle(context, e.title),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _MoviesView extends StatelessWidget {
  const _MoviesView({required this.state});
  final ScheduleState state;

  @override
  Widget build(BuildContext context) {
    if (state.loadingSoon) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    if (state.comingSoon.isEmpty) {
      return const _Empty(message: "Couldn't load coming soon — pull to refresh.");
    }
    // Flatten into month-section headers + rows so the list stays lazy.
    final byMonth = <String, List<ComingSoonEntry>>{};
    final order = <String>[];
    for (final e in state.comingSoon) {
      final label = e.releaseDate == null ? 'To be announced' : _monthYear(e.releaseDate!);
      if (!byMonth.containsKey(label)) {
        byMonth[label] = [];
        order.add(label);
      }
      byMonth[label]!.add(e);
    }
    final rows = <Widget>[];
    for (final label in order) {
      final items = byMonth[label]!;
      rows.add(_DayHeader(label: label, count: items.length));
      for (var i = 0; i < items.length; i++) {
        final e = items[i];
        final date = e.releaseDate != null ? ' · ${_monthDay(e.releaseDate!)}' : '';
        rows.add(_CompactRow(
          title: e.title,
          imageUrl: e.posterUrl,
          subtitle: '${e.isTv ? 'Series' : 'Movie'}$date',
          pill: null,
          onTap: () => openTitle(context, e.title),
        ));
        if (i < items.length - 1) {
          rows.add(const Divider(height: 1, indent: 74, color: AppColors.hairline));
        }
      }
    }
    return ListView(padding: const EdgeInsets.only(bottom: 24), children: rows);
  }
}

// ── pieces ───────────────────────────────────────────────────────────────────

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.days,
    required this.today,
    required this.selectedDay,
    required this.hasEntries,
    required this.onSelect,
  });
  final List<DateTime> days;
  final DateTime today;
  final DateTime selectedDay;
  final bool Function(DateTime) hasEntries;
  final ValueChanged<DateTime> onSelect;

  static const _wd = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 84,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        itemCount: days.length,
        itemBuilder: (context, i) {
          final d = days[i];
          final selected = d == selectedDay;
          final isToday = d == today;
          final dot = hasEntries(d);
          return GestureDetector(
            onTap: () => onSelect(d),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 48,
              margin: const EdgeInsets.only(right: 7),
              decoration: BoxDecoration(
                color: selected ? AppColors.accent : AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: selected ? AppColors.accent : AppColors.hairline),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    isToday ? 'TODAY' : _wd[d.weekday % 7].toUpperCase(),
                    style: AppText.caption.copyWith(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: selected ? Colors.white : AppColors.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${d.day}',
                    style: AppText.headline.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: selected ? Colors.white : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: !dot
                          ? Colors.transparent
                          : (selected ? Colors.white : AppColors.accent),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label, required this.count});
  final String label;
  final int count;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(label, style: AppText.headline.copyWith(fontWeight: FontWeight.w800)),
          const Spacer(),
          if (count > 0)
            Text('$count title${count == 1 ? '' : 's'}',
                style: AppText.caption.copyWith(color: AppColors.textTertiary)),
        ],
      ),
    );
  }
}

/// One compact schedule row: small poster thumb + title + subtitle, optional
/// trailing status pill.
class _CompactRow extends StatelessWidget {
  const _CompactRow({
    required this.title,
    required this.imageUrl,
    required this.subtitle,
    required this.onTap,
    this.pill,
  });
  final String title;
  final String? imageUrl;
  final String subtitle;
  final ({String text, Color bg, Color fg})? pill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: SizedBox(
                width: 44,
                height: 62,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: AppColors.surface2),
                    if (imageUrl != null)
                      Image.network(imageUrl!, fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox.shrink()),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppText.headline.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: AppText.caption.copyWith(color: AppColors.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (pill != null) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: pill!.bg,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppColors.hairline),
                ),
                child: Text(pill!.text,
                    style: AppText.caption.copyWith(
                        color: pill!.fg, fontWeight: FontWeight.w800, fontSize: 12)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Text(message, textAlign: TextAlign.center, style: AppText.caption),
      ),
    );
  }
}
