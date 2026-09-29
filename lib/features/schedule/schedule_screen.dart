import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/playback/my_list.dart';
import '../../core/schedule/airing_service.dart';
import '../../core/schedule/coming_soon_service.dart';
import '../../core/schedule/schedule_models.dart';
import '../../core/models/media_item.dart';
import '../../core/models/provider_info.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../detail/detail_screen.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../home/search_screen.dart';
import 'schedule_cubit.dart';
import 'schedule_screen_tv.dart';
import '../../l10n/l10n.dart';

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
      child: sl<AppMode>().isTv
          ? const ScheduleScreenTv()
          : const ScheduleBody(),
    );
  }
}

/// Search the user's sources for [title]. The fallback for a row we can't
/// identify — see [openCanonical], which is the normal path now.
void openTitle(BuildContext context, String title) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => SearchScreen(initialQuery: title)),
  );
}

/// Open a schedule row's Detail directly.
///
/// Every row used to bounce through Search, because the schedule was metadata
/// with no url of its own. It isn't any more: the calendar carries TMDB ids
/// and AniList carries MAL ids, which is exactly what a `zm://` url is made
/// of — so the row can go straight to the title. [CatalogueRouter] picks the
/// metadata repository off the url itself, so this works whether or not Z
/// Mode is on.
///
/// Falls back to [openTitle] when there is no id, which is the case for a
/// minority of AniList airings.
void openCanonical(
  BuildContext context, {
  required ZKind kind,
  required String? id,
  required String title,
  String? coverUrl,
}) {
  if (id == null || id.isEmpty) {
    openTitle(context, title);
    return;
  }
  final c = ZCanonical(kind, id);
  Navigator.of(context).push(
    DetailScreen.route(
      MediaItem(
        id: c.id,
        title: title,
        url: ZmodeIds.showUrl(c),
        // Matches what TmdbCatalogue/AniListCatalogue stamp on their own
        // items, so a row opened from here is the same shape as one opened
        // from Home rather than a lookalike.
        type: switch (kind) {
          ZKind.manga => ProviderType.manga,
          ZKind.novel => ProviderType.novel,
          ZKind.movie || ZKind.tv => ProviderType.movie,
          ZKind.anime => ProviderType.anime,
        },
        sourceId: ZmodeIds.sourceId,
        cover: coverUrl,
      ),
    ),
  );
}

// ── formatting helpers ───────────────────────────────────────────────────────

/// Live-green accent for "airing now" — not part of the app palette (which is
/// coral-only), scoped to the Schedule screen.
const Color _live = Color(0xFF3ED598);

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// "6:30" + separate "PM" — split so the rail can stack them.
({String hm, String ap}) _timeParts(DateTime d, String locale) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  final ap = DateFormat('a', locale).format(d);
  return (hm: '$h:$m', ap: ap);
}

String _monthDay(DateTime d, String locale) =>
    DateFormat.yMMMd(locale).format(d);

String _selectedHeader(
  AppLocalizations l10n,
  String locale,
  DateTime day,
  DateTime today,
) {
  if (day == today) return l10n.relativeToday;
  if (day == today.add(const Duration(days: 1))) return l10n.relativeTomorrow;
  return DateFormat('EEE, MMM d', locale).format(day);
}

/// Time-of-day slot label for grouping the timeline.
String _slotLabel(AppLocalizations l10n, int hour) {
  if (hour < 5 || hour >= 21) return l10n.scheduleSlotLateNight;
  if (hour < 12) return l10n.scheduleSlotMorning;
  if (hour < 17) return l10n.scheduleSlotAfternoon;
  return l10n.scheduleSlotEvening;
}

/// Countdown/live status for an episode. `live` = aired within the last 30 min.
({String text, bool live}) _airStatus(
  AppLocalizations l10n,
  DateTime airs,
  DateTime now,
) {
  final diff = airs.difference(now);
  if (diff.isNegative) {
    if (now.difference(airs) < const Duration(minutes: 30)) {
      return (text: l10n.scheduleLive, live: true);
    }
    return (text: l10n.scheduleAired, live: false);
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
    // Open on the tab for the kind you were browsing: Schedule is reached from
    // the Home card now, and arriving on Anime after tapping it from a
    // Movies/TV Home meant a tab switch every single time.
    _tabs =
        TabController(
          length: 2,
          vsync: this,
          initialIndex: ZModePrefs.streamKind == StreamKind.movie ? 1 : 0,
        )..addListener(() {
          if (mounted)
            setState(() {}); // header (My List / busy) follows the tab
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
                _tabRow(context, state, cubit),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _page(
                        context,
                        state,
                        cubit,
                        today,
                        selected,
                        forMovies: false,
                      ),
                      _page(
                        context,
                        state,
                        cubit,
                        today,
                        selected,
                        forMovies: true,
                      ),
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
  Widget _header(
    BuildContext context,
    ScheduleState state,
    ScheduleCubit cubit,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(context.l10n.schedule, style: AppText.largeTitle),
          ),
          // My List filter only applies to the anime tab; slide it in/out.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (c, a) => SizeTransition(
              axis: Axis.horizontal,
              sizeFactor: a,
              child: FadeTransition(opacity: a, child: c),
            ),
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
          color: on
              ? AppColors.accent.withValues(alpha: 0.14)
              : AppColors.surface2,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: on
                ? AppColors.accent.withValues(alpha: 0.4)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              on ? Icons.bookmark : Icons.bookmark_border,
              size: 16,
              color: on ? AppColors.accent : AppColors.textSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              context.l10n.myList,
              style: AppText.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: on ? AppColors.accent : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Anime/Movies TabBar (animated sliding underline) ──
  Widget _tabRow(
    BuildContext context,
    ScheduleState state,
    ScheduleCubit cubit,
  ) {
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
              indicator: UnderlineTabIndicator(
                borderSide: BorderSide(width: 3, color: AppColors.accent),
                borderRadius: BorderRadius.all(Radius.circular(3)),
                insets: EdgeInsets.only(bottom: 2),
              ),
              dividerColor: Colors.transparent,
              labelColor: AppColors.textPrimary,
              unselectedLabelColor: AppColors.textTertiary,
              labelStyle: AppText.headline.copyWith(fontSize: 14),
              unselectedLabelStyle: AppText.headline.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              tabs: [
                Tab(text: context.l10n.anime),
                Tab(text: context.l10n.moviesTV),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── one tab page: day selector + day content ──
  Widget _page(
    BuildContext context,
    ScheduleState state,
    ScheduleCubit cubit,
    DateTime today,
    DateTime selected, {
    required bool forMovies,
  }) {
    final counts = forMovies ? _soonDayCounts(state) : _animeByDay(state);
    // The day strip is pinned and only the CONTENT scrolls. It used to be the
    // first child of one big ListView whose second child was a Column holding
    // every row for the day — and a Movies day is ~330 rows (see
    // groupSoonByLocalDay), so all 330 cards and their images were built,
    // laid out and measured by AnimatedSize before a single frame, then again
    // on every 30s countdown tick. Pinning the strip lets the rows live in a
    // lazy builder, and keeps the day picker on screen through a long day.
    return Column(
      children: [
        _weekTabs(context, cubit, today, selected, counts),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.accent,
            backgroundColor: AppColors.surface,
            onRefresh: cubit.refresh,
            // Day content: fade + vertical slide on day / filter change.
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.06),
                    end: Offset.zero,
                  ).animate(anim),
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, ?current],
              ),
              child: KeyedSubtree(
                key: ValueKey(
                  'day-$forMovies-'
                  '${selected.millisecondsSinceEpoch}-${state.myListOnly}-'
                  '${_loadingFor(state, forMovies)}',
                ),
                child: _dayContent(context, state, today, selected, forMovies),
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool _loadingFor(ScheduleState state, bool forMovies) =>
      forMovies ? state.loadingSoon : state.loadingAiring;

  /// The scrollable half of a tab. Returns a scroll view rather than a Column
  /// so RefreshIndicator still has something to pull, and — for Movies —
  /// so the day's rows are built as they are reached instead of all at once.
  Widget _dayContent(
    BuildContext context,
    ScheduleState state,
    DateTime today,
    DateTime selected,
    bool forMovies,
  ) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    final bottom = MediaQuery.paddingOf(context).bottom;
    if (_loadingFor(state, forMovies)) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: bottom),
        children: const [_SkeletonTimeline()],
      );
    }

    if (!forMovies) {
      var list = state.airingByDay[selected] ?? const <AiringEntry>[];
      if (state.myListOnly) {
        list = list.where(state.followed.matches).toList();
      }
      // Anime is a handful of rows a day and the timeline draws its own
      // time-bucket headers across the whole list, so it stays one piece.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: bottom),
        children: [
          _dayHead(
            context,
            _selectedHeader(l10n, locale, selected, today),
            list.length,
            l10n.scheduleNounAiring,
          ),
          if (list.isEmpty)
            // "Nothing airing today" is a claim about the schedule. Don't make
            // it when the schedule never loaded.
            _empty(
              state.offline
                  ? '${l10n.offlineTitle}\n${l10n.offlineBody}'
                  : state.myListOnly
                  ? l10n.noneOfFollowedAirOnThisDay
                  : l10n.nothingAiringOnThisDay,
            )
          else
            _timeline(context, list),
        ],
      );
    }

    final list = state.soonByDay[selected] ?? const <ComingSoonEntry>[];
    if (list.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.only(bottom: bottom),
        children: [
          _dayHead(
            context,
            _selectedHeader(l10n, locale, selected, today),
            0,
            l10n.scheduleNounReleasing,
          ),
          _empty(
            state.offline
                ? '${l10n.offlineTitle}\n${l10n.offlineBody}'
                : l10n.nothingReleasingOnThisDay,
          ),
        ],
      );
    }
    // Index 0 is the day header, so the whole tab is ONE lazy list — a
    // separate header above it would need its own non-scrolling slot and
    // put the count out of sync with what is actually being scrolled.
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(bottom: bottom),
      itemCount: list.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return _dayHead(
            context,
            _selectedHeader(l10n, locale, selected, today),
            list.length,
            l10n.scheduleNounReleasing,
          );
        }
        final e = list[i - 1];
        return _ReleaseCard(
          title: e.title,
          imageUrl: e.posterUrl,
          // The TV calendar is per-episode, so one series appears on many
          // days — without its S/E the rows read as the same title over
          // and over. Prefixed onto the existing line rather than adding
          // a third, which would make every movie row taller for nothing.
          subtitle: [
            if (e.episodeLabel != null) e.episodeLabel!,
            e.isTv
                ? l10n.seriesWithDate(
                    _monthDay(e.releaseDate ?? selected, locale),
                  )
                : l10n.movieWithDate(
                    _monthDay(e.releaseDate ?? selected, locale),
                  ),
          ].join('  ·  '),
          onTap: () => openCanonical(
            context,
            kind: e.isTv ? ZKind.tv : ZKind.movie,
            id: 'tmdb:${e.tmdbId}',
            title: e.title,
            coverUrl: e.posterUrl,
          ),
        );
      },
    );
  }

  // ── week day tabs ("Mon, Jul 13 (12)", scrollable) ──────────────────
  Widget _weekTabs(
    BuildContext context,
    ScheduleCubit cubit,
    DateTime today,
    DateTime selected,
    Map<DateTime, ({int count, bool followed})> counts,
  ) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
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
              ? l10n.todayWithDate(DateFormat('MMM d', locale).format(d))
              : DateFormat('EEE, MMM d', locale).format(d);
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
                      Text(
                        label,
                        style: AppText.headline.copyWith(
                          fontSize: 14,
                          fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                          color: on
                              ? AppColors.textPrimary
                              : AppColors.textTertiary,
                        ),
                      ),
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
                      child: Text(
                        '($n)',
                        style: AppText.caption.copyWith(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: on ? AppColors.accent : AppColors.textTertiary,
                        ),
                      ),
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
  Widget _dayHead(BuildContext context, String label, int count, String noun) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              label,
              style: AppText.headline.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            if (count > 0)
              Text(
                context.l10n.scheduleCountDot(count, noun),
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
          ],
        ),
      );

  // Timeline: episodes sorted by time, grouped by slot header, time on the rail.
  Widget _timeline(BuildContext context, List<AiringEntry> list) {
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    final now = DateTime.now();
    final rows = <Widget>[];
    String? lastSlot;
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      final slot = _slotLabel(l10n, e.airsAtLocal.hour);
      if (slot != lastSlot) {
        rows.add(
          Padding(
            padding: EdgeInsets.fromLTRB(18, i == 0 ? 8 : 14, 18, 6),
            child: Text(
              slot,
              style: AppText.caption.copyWith(
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.textTertiary,
              ),
            ),
          ),
        );
        lastSlot = slot;
      }
      rows.add(
        _TimelineRow(
          entry: e,
          status: _airStatus(l10n, e.airsAtLocal, now),
          timeParts: _timeParts(e.airsAtLocal, locale),
          episodeLabel: l10n.episodeLabel(e.episode),
          last:
              i == list.length - 1 ||
              _slotLabel(l10n, list[i + 1].airsAtLocal.hour) != slot,
          onTap: () => openCanonical(
            context,
            kind: ZKind.anime,
            id: e.malId == null ? null : 'mal:${e.malId}',
            title: e.title,
            coverUrl: e.coverUrl,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }

  Widget _empty(String message) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 36),
    child: Center(
      child: Text(message, textAlign: TextAlign.center, style: AppText.caption),
    ),
  );

  // ── per-day count/followed for the week strip ──
  Map<DateTime, ({int count, bool followed})> _animeByDay(ScheduleState state) {
    final src = state.airingByDay;
    final out = <DateTime, ({int count, bool followed})>{};
    src.forEach((day, entries) {
      final filtered = state.myListOnly
          ? entries.where(state.followed.matches).toList()
          : entries;
      if (filtered.isEmpty) return;
      final followed = filtered.any(state.followed.matches);
      out[day] = (count: filtered.length, followed: followed);
    });
    return out;
  }

  Map<DateTime, ({int count, bool followed})> _soonDayCounts(
    ScheduleState state,
  ) {
    final out = <DateTime, ({int count, bool followed})>{};
    state.soonByDay.forEach((day, entries) {
      out[day] = (count: entries.length, followed: false);
    });
    return out;
  }
}

// ── calendar grid ─────────────────────────────────────────────────────────────


// ── timeline row (anime) ──────────────────────────────────────────────────────

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.entry,
    required this.status,
    required this.timeParts,
    required this.episodeLabel,
    required this.last,
    required this.onTap,
  });
  final AiringEntry entry;
  final ({String text, bool live}) status;
  final ({String hm, String ap}) timeParts;
  final String episodeLabel;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = timeParts;
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
                  Text(
                    t.hm,
                    style: AppText.caption.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  Text(
                    t.ap,
                    style: AppText.caption.copyWith(
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textTertiary,
                    ),
                  ),
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
                            Text(
                              entry.title,
                              style: AppText.headline.copyWith(fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              episodeLabel,
                              style: AppText.caption.copyWith(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        status.text,
                        style: AppText.caption.copyWith(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: live ? _live : AppColors.accent,
                        ),
                      ),
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
                  Text(
                    title,
                    style: AppText.headline.copyWith(fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
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
        ColoredBox(color: AppColors.surface2),
        if (url != null)
          Image.network(
            url,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
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
                  Expanded(child: _box(height: 66)),
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

  Widget _bar({
    required double width,
    required double height,
    Alignment? align,
  }) {
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
