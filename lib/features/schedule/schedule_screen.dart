import 'dart:async';

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

/// The Schedule tab: a monthly/weekly anime airing calendar + upcoming
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

/// Live-green accent for "airing now" — not part of the app palette (which is
/// coral-only), scoped to the Schedule screen.
const Color _live = Color(0xFF3ED598);

const _wdShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']; // Mon=1..Sun=7
const _monShort = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const _monFull = ['January','February','March','April','May','June','July',
  'August','September','October','November','December'];

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// "6:30" + separate "PM" — split so the rail can stack them.
({String hm, String ap}) _timeParts(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return (hm: '$h:$m', ap: d.hour < 12 ? 'AM' : 'PM');
}

String _monthYear(DateTime d) => '${_monFull[d.month - 1]} ${d.year}';
String _monthDay(DateTime d) => '${_monShort[d.month - 1]} ${d.day}, ${d.year}';

String _selectedHeader(DateTime day, DateTime today) {
  if (day == today) return 'Today';
  if (day == today.add(const Duration(days: 1))) return 'Tomorrow';
  return '${_wdShort[day.weekday - 1]}, ${_monShort[day.month - 1]} ${day.day}';
}

/// Time-of-day slot label for grouping the timeline.
String _slotLabel(int hour) {
  if (hour < 5 || hour >= 21) return 'LATE NIGHT';
  if (hour < 12) return 'MORNING';
  if (hour < 17) return 'AFTERNOON';
  return 'EVENING';
}

/// Countdown/live status for an episode. `live` = aired within the last 30 min.
({String text, bool live}) _airStatus(DateTime airs, DateTime now) {
  final diff = airs.difference(now);
  if (diff.isNegative) {
    if (now.difference(airs) < const Duration(minutes: 30)) {
      return (text: '● LIVE', live: true);
    }
    return (text: 'Aired', live: false);
  }
  if (diff.inMinutes < 60) return (text: '${diff.inMinutes}m', live: false);
  if (diff.inHours < 24) {
    return (text: '${diff.inHours}h ${diff.inMinutes % 60}m', live: false);
  }
  return (text: '${diff.inDays}d ${diff.inHours % 24}h', live: false);
}

// ── screen body ──────────────────────────────────────────────────────────────

class ScheduleBody extends StatefulWidget {
  const ScheduleBody({super.key});
  @override
  State<ScheduleBody> createState() => _ScheduleBodyState();
}

class _ScheduleBodyState extends State<ScheduleBody>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Timer? _tick; // refreshes the live countdowns

  int get _tab => _tabs.index;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this)
      ..addListener(() {
        if (mounted) setState(() {}); // header (My List / busy) follows the tab
      });
    // Re-render every 30s so countdowns/“LIVE” stay current. Cancelled in
    // dispose, so no timer leaks in tests.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = _dayOf(DateTime.now());
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        bottom: false,
        child: BlocBuilder<ScheduleCubit, ScheduleState>(
          builder: (context, state) {
            final cubit = context.read<ScheduleCubit>();
            final selected = state.selectedDay ?? today;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(context, state, cubit),
                _tabRow(state, cubit),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _page(context, state, cubit, today, selected,
                          forMovies: false),
                      _page(context, state, cubit, today, selected,
                          forMovies: true),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── header: title + My List toggle ──
  // Refresh lives in the pull-to-refresh gesture; no header button needed.
  Widget _header(BuildContext context, ScheduleState state, ScheduleCubit cubit) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
      child: Row(
        children: [
          Expanded(child: Text('Schedule', style: AppText.largeTitle)),
          // My List filter only applies to the anime tab; slide it in/out.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (c, a) => SizeTransition(
                axis: Axis.horizontal, sizeFactor: a,
                child: FadeTransition(opacity: a, child: c)),
            child: _tab == 0
                ? _myListToggle(state, cubit)
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _myListToggle(ScheduleState state, ScheduleCubit cubit) {
    final on = state.myListOnly;
    return GestureDetector(
      key: const ValueKey('mylist'),
      onTap: cubit.toggleMyListOnly,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
        decoration: BoxDecoration(
          color: on ? AppColors.accent.withValues(alpha: 0.14) : AppColors.surface2,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: on ? AppColors.accent.withValues(alpha: 0.4) : Colors.transparent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(on ? Icons.bookmark : Icons.bookmark_border,
                size: 16, color: on ? AppColors.accent : AppColors.textSecondary),
            const SizedBox(width: 5),
            Text('My List',
                style: AppText.caption.copyWith(
                  fontWeight: FontWeight.w600,
                  color: on ? AppColors.accent : AppColors.textSecondary,
                )),
          ],
        ),
      ),
    );
  }

  // ── Anime/Movies TabBar (animated sliding underline) + Week/Month pill ──
  Widget _tabRow(ScheduleState state, ScheduleCubit cubit) {
    Widget wm(String label, ScheduleView v) {
      final on = state.view == v;
      return GestureDetector(
        onTap: () => cubit.setView(v),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: on ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(label,
              style: AppText.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: on ? Colors.white : AppColors.textSecondary,
              )),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              padding: EdgeInsets.zero,
              labelPadding: const EdgeInsets.only(right: 24),
              // .label → the bar matches the word width exactly (no padding
              // gap). Thin height.
              indicatorSize: TabBarIndicatorSize.label,
              indicator: const UnderlineTabIndicator(
                borderSide: BorderSide(width: 3, color: AppColors.accent),
                borderRadius: BorderRadius.all(Radius.circular(3)),
                insets: EdgeInsets.only(bottom: 2),
              ),
              dividerColor: Colors.transparent,
              labelColor: AppColors.textPrimary,
              unselectedLabelColor: AppColors.textTertiary,
              labelStyle: AppText.headline.copyWith(fontSize: 14),
              unselectedLabelStyle:
                  AppText.headline.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
              tabs: const [Tab(text: 'Anime'), Tab(text: 'Movies & TV')],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(children: [
              wm('Week', ScheduleView.week),
              wm('Month', ScheduleView.month),
            ]),
          ),
        ],
      ),
    );
  }

  // ── one tab page: day selector + day content ──
  Widget _page(BuildContext context, ScheduleState state, ScheduleCubit cubit,
      DateTime today, DateTime selected, {required bool forMovies}) {
    final isMonth = state.view == ScheduleView.month;
    final counts = forMovies
        ? _soonDayCounts(state)
        : _animeByDay(state, month: isMonth);
    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: cubit.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding:
            EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
        children: [
          // Day selector: cross-fade between week tabs and month grid.
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: KeyedSubtree(
                key: ValueKey('sel-$isMonth-${state.monthAnchor}'),
                child: isMonth
                    ? _monthSelector(state, cubit, today, selected, counts)
                    : _weekTabs(cubit, today, selected, counts),
              ),
            ),
          ),
          // Day content: fade + vertical slide on day / view / filter change.
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                          begin: const Offset(0, 0.06), end: Offset.zero)
                      .animate(anim),
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, ?current],
              ),
              child: KeyedSubtree(
                key: ValueKey('day-$forMovies-${state.view}-'
                    '${selected.millisecondsSinceEpoch}-${state.myListOnly}-'
                    '${_loadingFor(state, forMovies)}'),
                child: _dayContent(context, state, today, selected, forMovies),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _loadingFor(ScheduleState state, bool forMovies) => forMovies
      ? state.loadingSoon
      : (state.view == ScheduleView.month
          ? state.loadingMonth
          : state.loadingAiring);

  Widget _dayContent(BuildContext context, ScheduleState state, DateTime today,
      DateTime selected, bool forMovies) {
    if (_loadingFor(state, forMovies)) return const _SkeletonTimeline();

    if (!forMovies) {
      final byDay = state.view == ScheduleView.month
          ? state.monthAiringByDay
          : state.airingByDay;
      var list = byDay[selected] ?? const <AiringEntry>[];
      if (state.myListOnly) {
        list = list
            .where((e) => e.malId != null && state.followedMalIds.contains(e.malId))
            .toList();
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _dayHead(_selectedHeader(selected, today), list.length, 'airing'),
          if (list.isEmpty)
            _empty(state.myListOnly
                ? 'None of the anime you follow air on this day.'
                : 'Nothing airing on this day.')
          else
            _timeline(context, list),
        ],
      );
    }

    final list = state.soonByDay[selected] ?? const <ComingSoonEntry>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _dayHead(_selectedHeader(selected, today), list.length, 'releasing'),
        if (list.isEmpty)
          _empty('Nothing releasing on this day.')
        else
          for (final e in list)
            _ReleaseCard(
              title: e.title,
              imageUrl: e.posterUrl,
              subtitle: e.isTv
                  ? 'Series · ${_monthDay(e.releaseDate ?? selected)}'
                  : 'Movie · ${_monthDay(e.releaseDate ?? selected)}',
              onTap: () => openTitle(context, e.title),
            ),
      ],
    );
  }

  // ── week day tabs (Dantotsu-style: "Mon, Jul 13 (12)", scrollable) ──
  Widget _weekTabs(ScheduleCubit cubit, DateTime today, DateTime selected,
      Map<DateTime, ({int count, bool followed})> counts) {
    final days = [for (var i = 0; i < 7; i++) today.add(Duration(days: i))];
    return SizedBox(
      height: 46,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: days.length,
        itemBuilder: (context, i) {
          final d = days[i];
          final on = d == selected;
          final n = counts[d]?.count ?? 0;
          final label = d == today
              ? 'Today, ${_monShort[d.month - 1]} ${d.day}'
              : '${_wdShort[d.weekday - 1]}, ${_monShort[d.month - 1]} ${d.day}';
          return GestureDetector(
            onTap: () => cubit.selectDay(d),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Day label + a FIXED-width underline centered under it, so
                  // every day's bar is the same size regardless of how long the
                  // day name is (Today vs Wed vs Thu) — consistent, not ragged.
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Text(label,
                          style: AppText.headline.copyWith(
                            fontSize: 14,
                            fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                            color: on
                                ? AppColors.textPrimary
                                : AppColors.textTertiary,
                          )),
                      const SizedBox(height: 6),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 200),
                        opacity: on ? 1 : 0,
                        child: Container(
                          height: 3,
                          width: 28,
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Count stays visible, to the right, not underlined.
                  if (n > 0) ...[
                    const SizedBox(width: 5),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('($n)',
                          style: AppText.caption.copyWith(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color:
                                on ? AppColors.accent : AppColors.textTertiary,
                          )),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── month nav + calendar grid ──
  Widget _monthSelector(ScheduleState state, ScheduleCubit cubit, DateTime today,
      DateTime selected, Map<DateTime, ({int count, bool followed})> byDay) {
    final anchor = state.monthAnchor ?? DateTime(today.year, today.month, 1);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
          child: Row(
            children: [
              _navArrow(Icons.chevron_left,
                  () => cubit.goToMonth(DateTime(anchor.year, anchor.month - 1, 1))),
              Expanded(
                child: Text(_monthYear(anchor),
                    textAlign: TextAlign.center,
                    style: AppText.headline.copyWith(fontWeight: FontWeight.w800)),
              ),
              _navArrow(Icons.chevron_right,
                  () => cubit.goToMonth(DateTime(anchor.year, anchor.month + 1, 1))),
            ],
          ),
        ),
        _CalendarGrid(
          anchor: anchor,
          today: today,
          selected: selected,
          count: (d) => byDay[d]?.count ?? 0,
          followed: (d) => byDay[d]?.followed ?? false,
          onSelect: cubit.selectDay,
        ),
      ],
    );
  }

  Widget _navArrow(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: const BoxDecoration(
              color: AppColors.surface, shape: BoxShape.circle),
          child: Icon(icon, size: 18, color: AppColors.textSecondary),
        ),
      );

  Widget _dayHead(String label, int count, String noun) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(label,
                style: AppText.headline.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(width: 8),
            if (count > 0)
              Text('· $count $noun',
                  style: AppText.caption.copyWith(color: AppColors.textSecondary)),
          ],
        ),
      );

  // Timeline: episodes sorted by time, grouped by slot header, time on the rail.
  Widget _timeline(BuildContext context, List<AiringEntry> list) {
    final now = DateTime.now();
    final rows = <Widget>[];
    String? lastSlot;
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      final slot = _slotLabel(e.airsAtLocal.hour);
      if (slot != lastSlot) {
        rows.add(Padding(
          padding: EdgeInsets.fromLTRB(18, i == 0 ? 8 : 14, 18, 6),
          child: Text(slot,
              style: AppText.caption.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.textTertiary,
              )),
        ));
        lastSlot = slot;
      }
      rows.add(_TimelineRow(
        entry: e,
        status: _airStatus(e.airsAtLocal, now),
        last: i == list.length - 1 ||
            _slotLabel(list[i + 1].airsAtLocal.hour) != slot,
        onTap: () => openTitle(context, e.title),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _empty(String message) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 36),
        child: Center(
          child: Text(message,
              textAlign: TextAlign.center, style: AppText.caption),
        ),
      );

  // ── per-day count/followed for grid + week dots ──
  Map<DateTime, ({int count, bool followed})> _animeByDay(ScheduleState state,
      {required bool month}) {
    final src = month ? state.monthAiringByDay : state.airingByDay;
    final out = <DateTime, ({int count, bool followed})>{};
    src.forEach((day, entries) {
      final filtered = state.myListOnly
          ? entries
              .where((e) =>
                  e.malId != null && state.followedMalIds.contains(e.malId))
              .toList()
          : entries;
      if (filtered.isEmpty) return;
      final followed = filtered
          .any((e) => e.malId != null && state.followedMalIds.contains(e.malId));
      out[day] = (count: filtered.length, followed: followed);
    });
    return out;
  }

  Map<DateTime, ({int count, bool followed})> _soonDayCounts(
      ScheduleState state) {
    final out = <DateTime, ({int count, bool followed})>{};
    state.soonByDay.forEach((day, entries) {
      out[day] = (count: entries.length, followed: false);
    });
    return out;
  }
}

// ── calendar grid ─────────────────────────────────────────────────────────────

class _CalendarGrid extends StatelessWidget {
  const _CalendarGrid({
    required this.anchor,
    required this.today,
    required this.selected,
    required this.count,
    required this.followed,
    required this.onSelect,
  });

  final DateTime anchor; // first of displayed month
  final DateTime today;
  final DateTime selected;
  final int Function(DateTime) count;
  final bool Function(DateTime) followed;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final first = DateTime(anchor.year, anchor.month, 1);
    final daysInMonth = DateTime(anchor.year, anchor.month + 1, 0).day;
    final leading = first.weekday - 1; // Mon-first
    final weeks = ((leading + daysInMonth + 6) ~/ 7);
    final start = first.subtract(Duration(days: leading));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        children: [
          Row(
            children: [
              for (final w in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(w,
                        textAlign: TextAlign.center,
                        style: AppText.caption.copyWith(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textTertiary,
                        )),
                  ),
                ),
            ],
          ),
          for (var week = 0; week < weeks; week++)
            Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: _cell(start.add(Duration(days: week * 7 + col))),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _cell(DateTime date) {
    final inMonth = date.month == anchor.month;
    final isToday = date == today;
    final isSel = date == selected;
    final n = inMonth ? count(date) : 0;
    final hasFollowed = inMonth && followed(date);
    return GestureDetector(
      onTap: inMonth ? () => onSelect(date) : null,
      behavior: HitTestBehavior.opaque,
      child: AspectRatio(
        aspectRatio: 1,
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: isSel ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
            border: (isToday && !isSel)
                ? Border.all(
                    color: AppColors.accent.withValues(alpha: 0.55), width: 1.5)
                : null,
          ),
          child: Stack(
            children: [
              if (n > 0)
                Positioned(
                  top: 4,
                  right: 6,
                  child: Text('$n',
                      style: AppText.caption.copyWith(
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        color: isSel ? Colors.white : AppColors.textTertiary,
                      )),
                ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${date.day}',
                        style: AppText.headline.copyWith(
                          fontSize: 12.5,
                          color: isSel
                              ? Colors.white
                              : !inMonth
                                  ? AppColors.textTertiary.withValues(alpha: 0.4)
                                  : isToday
                                      ? AppColors.accent
                                      : AppColors.textPrimary,
                        )),
                    const SizedBox(height: 3),
                    SizedBox(
                      height: 4,
                      child: (n > 0)
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _dot(isSel ? Colors.white : AppColors.accent),
                                if (hasFollowed) ...[
                                  const SizedBox(width: 2),
                                  _dot(isSel ? Colors.white : _live),
                                ],
                              ],
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dot(Color c) => Container(
      width: 4, height: 4, decoration: BoxDecoration(color: c, shape: BoxShape.circle));
}

// ── timeline row (anime) ──────────────────────────────────────────────────────

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.entry,
    required this.status,
    required this.last,
    required this.onTap,
  });
  final AiringEntry entry;
  final ({String text, bool live}) status;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = _timeParts(entry.airsAtLocal);
    final live = status.live;
    return IntrinsicHeight(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Time rail.
            SizedBox(
              width: 42,
              child: Column(
                children: [
                  Text(t.hm,
                      style: AppText.caption.copyWith(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textSecondary,
                      )),
                  Text(t.ap,
                      style: AppText.caption.copyWith(
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textTertiary,
                      )),
                  if (!last)
                    Expanded(
                      child: Container(
                        width: 1.5,
                        margin: const EdgeInsets.only(top: 4),
                        color: AppColors.hairline,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 11),
            // Chip.
            Expanded(
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: live
                        ? _live.withValues(alpha: 0.08)
                        : AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: live
                        ? Border.all(color: _live.withValues(alpha: 0.3))
                        : null,
                  ),
                  child: Row(
                    children: [
                      _thumb(entry.coverUrl, 36, 50),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(entry.title,
                                style: AppText.headline.copyWith(fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 2),
                            Text('Episode ${entry.episode}',
                                style: AppText.caption.copyWith(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textTertiary,
                                )),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(status.text,
                          style: AppText.caption.copyWith(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: live ? _live : AppColors.accent,
                          )),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── release card (movies) ─────────────────────────────────────────────────────

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({
    required this.title,
    required this.imageUrl,
    required this.subtitle,
    required this.onTap,
  });
  final String title;
  final String? imageUrl;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            _thumb(imageUrl, 44, 62),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppText.headline.copyWith(fontSize: 14),
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
          ],
        ),
      ),
    );
  }
}

// Shared poster thumbnail (dark placeholder, silent on error).
Widget _thumb(String? url, double w, double h) => ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: AppColors.surface2),
            if (url != null)
              Image.network(url, fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink()),
          ],
        ),
      ),
    );

// ── skeleton loader ───────────────────────────────────────────────────────────

/// Pulsing grey placeholder rows shown while a day's list loads — replaces the
/// bare spinner so the screen feels responsive (especially the slower month
/// fetch). Self-contained ticker so it doesn't touch the body's controllers.
class _SkeletonTimeline extends StatefulWidget {
  const _SkeletonTimeline();
  @override
  State<_SkeletonTimeline> createState() => _SkeletonTimelineState();
}

class _SkeletonTimelineState extends State<_SkeletonTimeline>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.4, end: 0.9).animate(_c),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          children: [
            _bar(width: 120, height: 12, align: Alignment.centerLeft),
            const SizedBox(height: 14),
            for (var i = 0; i < 5; i++) ...[
              Row(
                children: [
                  _bar(width: 34, height: 12),
                  const SizedBox(width: 11),
                  Expanded(
                    child: _box(height: 66),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  Widget _box({required double height}) => Container(
        height: height,
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
      );

  Widget _bar({required double width, required double height, Alignment? align}) {
    final b = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return align == null ? b : Align(alignment: align, child: b);
  }
}
