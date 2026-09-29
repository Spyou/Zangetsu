import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/schedule/schedule_models.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import 'schedule_cubit.dart';
import 'schedule_screen.dart' show openTitle;
import '../../l10n/l10n.dart';

String _fmtTime(DateTime d, String locale) => DateFormat.jm(locale).format(d);

({String text, Color bg, Color fg})? _airPill(
  AppLocalizations l10n,
  DateTime airs,
  DateTime now,
) {
  final diff = airs.difference(now);
  if (diff.isNegative) {
    return (text: l10n.scheduleAired, bg: Colors.black54, fg: AppColors.textSecondary);
  }
  if (diff.inMinutes < 60) {
    return (text: l10n.scheduleSoon, bg: AppColors.accent, fg: Colors.white);
  }
  if (diff.inHours < 24) {
    return (text: l10n.scheduleInHours(diff.inHours), bg: Colors.black54, fg: Colors.white);
  }
  return (text: l10n.scheduleInDays(diff.inDays), bg: Colors.black54, fg: Colors.white);
}

String _monthDay(DateTime d, String locale) => DateFormat.yMMMd(locale).format(d);

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
    final l10n = context.l10n;
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
              child: Text(l10n.schedule, style: AppText.title),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Row(
                children: [
                  TvFocusable(
                    autofocus: true,
                    variant: TvFocusVariant.float,
                    scale: 1.0,
                    borderRadius: 20,
                    onTap: () => setState(() => _tab = 0),
                    child: _Chip(label: l10n.anime, selected: _tab == 0),
                  ),
                  const SizedBox(width: 12),
                  TvFocusable(
                    variant: TvFocusVariant.float,
                    scale: 1.0,
                    borderRadius: 20,
                    onTap: () => setState(() => _tab = 1),
                    child: _Chip(label: l10n.moviesTV, selected: _tab == 1),
                  ),
                  const SizedBox(width: 12),
                  TvFocusable(
                    variant: TvFocusVariant.float,
                    scale: 1.0,
                    borderRadius: 20,
                    onTap: () => setState(() => _tab = 2),
                    child: _Chip(label: l10n.myList, selected: _tab == 2),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (showDays) ...[
              _DayChipRow(days: days, selectedDay: _selectedDay, onSelect: (d) => setState(() => _selectedDay = d)),
              const SizedBox(height: 8),
            ],
            Expanded(child: _body(state)),
          ],
        ),
      ),
    );
  }

  Widget _body(ScheduleState state) {
    final l10n = context.l10n;
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
                ? l10n.noneOfFollowedAirOnThisDay
                : l10n.nothingAiringOnThisDay,
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
      color: selected ? AppColors.accent.withValues(alpha: 0.18) : AppColors.surface2,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: selected ? AppColors.accent : Colors.transparent, width: 2),
    ),
    child: Text(
      label,
      style: AppText.headline.copyWith(color: selected ? AppColors.accent : AppColors.textSecondary, fontSize: 15),
    ),
  );
}

class _DayChipRow extends StatelessWidget {
  const _DayChipRow({required this.days, required this.selectedDay, required this.onSelect});
  final List<DateTime> days;
  final DateTime selectedDay;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
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
          final label = i == 0
              ? context.l10n.relativeToday
              : '${DateFormat('EEE', locale).format(d)} ${d.day}';
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Align(
              child: TvFocusable(
                variant: TvFocusVariant.float,
                scale: 1.0,
                borderRadius: 20,
                onTap: () => onSelect(d),
                child: _Chip(
                  label: label,
                  selected: selected,
                ),
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
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    final now = DateTime.now();
    return _Rail(
      count: entries.length,
      builder: (context, i) {
        final e = entries[i];
        return _PosterTile(
          title: e.title,
          imageUrl: e.coverUrl,
          subtitle: l10n.epWithTime('${e.episode}', _fmtTime(e.airsAtLocal, locale)),
          pill: _airPill(l10n, e.airsAtLocal, now),
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
      return Center(child: Text(context.l10n.couldnTLoadComingSoonPullToRefresh, style: AppText.caption));
    }
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    return _Rail(
      count: entries.length,
      builder: (context, i) {
        final e = entries[i];
        final date = e.releaseDate != null ? ' · ${_monthDay(e.releaseDate!, locale)}' : '';
        return _PosterTile(
          title: e.title,
          imageUrl: e.posterUrl,
          subtitle: '${e.isTv ? l10n.series : l10n.movie}$date',
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
          child: Align(alignment: Alignment.topCenter, child: builder(context, i)),
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
  static const double imageHeight = 190;
  static const double cardHeight = imageHeight + 30;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: cardWidth,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: imageHeight,
            child: TvFocusable(
              variant: TvFocusVariant.float,
              scale: 1.06,
              onTap: onTap,
              focusLabel: title,
              child: ClipRRect(
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
                        Image.network(imageUrl!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                      if (pill != null)
                        Positioned(
                          left: 6,
                          top: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(color: pill!.bg, borderRadius: BorderRadius.circular(999)),
                            child: Text(
                              pill!.text,
                              style: AppText.caption.copyWith(
                                color: pill!.fg,
                                fontWeight: FontWeight.w800,
                                fontSize: 10.5,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(fontSize: 11)),
        ],
      ),
    );
  }
}
