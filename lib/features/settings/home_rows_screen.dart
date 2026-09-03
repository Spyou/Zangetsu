import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/home_row.dart';
import '../../core/models/watch_status.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/ui/home_rows_prefs.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/zmode/metadata_provider_prefs.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart' show browseKindFor;
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';
import '../home/cubit/home_cubit.dart';
import '../home/cubit/home_rows_composer.dart';
import '../home/cubit/tracker_home_rows.dart';
import '../home/tracker_continue_section.dart';

/// The home-rows editor (Settings → Appearance → Home rows, phone only).
///
/// Edits the arrangement of the CURRENT home layout — the same layout key the
/// cubit merges with — so what you see here is what Home renders next. Rows
/// keep their saved order verbatim; the two group labels ("From your lists" /
/// "Discover") are anchored above each group's first row, not fixed slots, so
/// dragging a row across groups is a real move. Every change saves and bumps
/// [HomeRowsPrefs.revision], which reloads Home live behind this screen. TV
/// has no editor; it mirrors whatever was saved here.
class HomeRowsScreen extends StatefulWidget {
  const HomeRowsScreen({super.key});

  @override
  State<HomeRowsScreen> createState() => _HomeRowsScreenState();
}

class _HomeRowsScreenState extends State<HomeRowsScreen> {
  /// Computed once: the editor edits one layout per visit, and the mode can't
  /// change under a pushed screen.
  late final String _layoutKey;
  late final bool _withTrackerRows;

  /// The browse kind of the layout being edited, or null when source-backed.
  ZKind? _kind;

  /// The sanitized arrangement being edited, in saved order. False until Home
  /// has sections to offer (its load finished); editing without them could
  /// save a sectionless layout over a sectioned one.
  List<HomeRowEntry> _layout = const [];
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _kind = _browseKind();
    _withTrackerRows = _kind != null;
    final providerPrefs = sl.isRegistered<MetadataProviderPrefs>()
        ? sl<MetadataProviderPrefs>()
        : null;
    _layoutKey = layoutKeyFor(
      sourceId: sl.isRegistered<CatalogueRepository>()
          ? sl<CatalogueRepository>().sourceId
          : '',
      zModeOn: _kind != null,
      browseKind: _kind,
      malPreferred: providerPrefs?.anime == AnimeProvider.mal,
      simklPreferred: providerPrefs?.video == VideoProvider.simkl,
    );
    _reload();
  }

  /// Re-derive the arrangement from the same inputs the cubit merges with:
  /// Home's raw sections (phone row rule), the saved layout for this key, or
  /// the shipped default when none was saved.
  void _reload() {
    final sections = sl.isRegistered<HomeCubit>()
        ? sl<HomeCubit>().state.sections
        : null;
    if (sections == null) return; // not loaded yet — nothing safe to edit
    final rowSections = providerRowSections(sections, isTv: false);
    final stored =
        HomeRowsPrefs.savedFor(_layoutKey) ??
        defaultLayout(
          [for (final s in rowSections) 'section:${s.title}'],
          withTrackerRows: _withTrackerRows,
        );
    _layout = sanitizeLayout(
      stored,
      availableRowIds(rowSections, withTrackerRows: _withTrackerRows),
    );
    _ready = true;
  }

  /// Same rule as the cubit's pick: mode and stream kind read live, Z Mode
  /// decides whether a source backs the home at all.
  ZKind? _browseKind() {
    if (!ZModePrefs.enabled) return null;
    final mode = sl.isRegistered<ContentModeCubit>()
        ? sl<ContentModeCubit>().state
        : ContentMode.anime;
    return browseKindFor(mode, ZModePrefs.streamKind);
  }

  /// The tracker the rows would come from: the connected pick, else the first
  /// one in hub order that could serve this layout, so the labels read the
  /// same before and after a sign-in.
  String get _trackerName {
    final kind = _kind;
    if (kind == null || !sl.isRegistered<TrackerHub>()) return 'AniList';
    final hub = sl<TrackerHub>();
    Tracker? pick = pickHomeTracker(hub, kind);
    for (final t in hub.trackers) {
      if (pick != null) break;
      if (trackerServesKind(t, kind)) pick = t;
    }
    return pick?.displayName ?? 'AniList';
  }

  /// Reading layouts relabel the status rows ("Reading", "Plan to read"),
  /// exactly like the rows do on Home.
  bool get _reading => _kind == ZKind.manga || _kind == ZKind.novel;

  Future<void> _save() => HomeRowsPrefs.save(
    _layoutKey,
    [for (final e in _layout) encodeRowEntry(e)],
  );

  void _toggle(HomeRowEntry entry, bool shown) {
    setState(() {
      _layout = [
        for (final e in _layout)
          if (e.id == entry.id) HomeRowEntry(e.id, !shown) else e,
      ];
    });
    _save();
  }

  Future<void> _reset() async {
    await HomeRowsPrefs.resetFor(_layoutKey);
    if (!mounted) return;
    setState(() => _reload());
  }

  /// The list as rendered: group labels anchored above each group's first row,
  /// interleaved with the entries. Purely a projection — re-running it after a
  /// drag re-anchors the labels around the new order, so this screen and a
  /// fresh visit can't disagree.
  List<Object> _arrangement() {
    final out = <Object>[const _GroupTag.yours()];
    var discover = false;
    for (final e in _layout) {
      if (!discover && e.id.startsWith('section:')) {
        out.add(const _GroupTag.discover());
        discover = true;
      }
      out.add(e);
    }
    return out;
  }

  /// [ReorderableListView.onReorderItem]'s newIndex is already adjusted for
  /// the removed row. Nothing may land above the first group label, so index 0
  /// is a floor.
  void _reorder(int oldIndex, int newIndex) {
    final items = _arrangement();
    final moved = items.removeAt(oldIndex);
    items.insert(newIndex < 1 ? 1 : newIndex, moved);
    setState(() {
      _layout = [for (final o in items) if (o is HomeRowEntry) o];
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final arrangement = _arrangement();
    final canReset = HomeRowsPrefs.savedFor(_layoutKey) != null;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        l10n.homeRows,
        actions: [
          TextButton(
            onPressed: canReset ? _reset : null,
            child: Text(
              l10n.reset,
              style: AppText.button.copyWith(
                color: canReset ? AppColors.accent : AppColors.textTertiary,
              ),
            ),
          ),
        ],
      ),
      body:
          _ready
              ? ListView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                children: [
                  SettingsCard(
                    children: [
                      ReorderableListView(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        buildDefaultDragHandles: false,
                        onReorderItem: _reorder,
                        children: [
                          for (var i = 0; i < arrangement.length; i++)
                            if (arrangement[i] is _GroupTag)
                              _groupLabel(arrangement[i] as _GroupTag, i)
                            else
                              _row(arrangement[i] as HomeRowEntry, i),
                        ],
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
                    child: Text(
                      l10n.homeRowsHelp,
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                ],
              )
              : Center(
                // Home hasn't finished a load; its sections are half of what
                // this editor edits, so wait rather than offer half a list.
                child: Text(l10n.loading, style: AppText.caption),
              ),
    );
  }

  /// A group header inside the card — [SettingsSectionLabel]'s look at list
  /// scale. Keyed (ReorderableListView requires it) but never draggable: with
  /// default drag handles off, only rows carry a drag listener.
  Widget _groupLabel(_GroupTag tag, int index) {
    final l10n = context.l10n;
    return Padding(
      key: ValueKey('label_${tag.group}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
      child: Text(
        (tag.isYours ? l10n.homeRowsFromYourLists : l10n.homeRowsDiscover)
            .toUpperCase(),
        style: TextStyle(
          fontFamily: 'Inter',
          fontFamilyFallback: AppText.fontFamilyFallback,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: AppColors.accent,
        ),
      ),
    );
  }

  Widget _row(HomeRowEntry e, int index) {
    final tint = e.hidden ? AppColors.textTertiary : AppColors.textPrimary;
    return Padding(
      key: ValueKey(e.id),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.only(right: 10),
              child: Icon(
                Icons.drag_indicator_rounded,
                size: 19,
                color: AppColors.textTertiary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              _rowTitle(e),
              style: AppText.body.copyWith(color: tint, fontSize: 14.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Switch.adaptive(
            value: !e.hidden,
            activeThumbColor: AppColors.accent,
            onChanged: (v) => _toggle(e, v),
          ),
        ],
      ),
    );
  }

  /// One row's label, resolved the same way Home renders it — shared helpers
  /// and l10n keys, so editor and screen can't drift.
  String _rowTitle(HomeRowEntry e) {
    final l10n = context.l10n;
    final id = e.id;
    if (id == localContinueRowId) return l10n.continueWatching;
    if (id == trackerContinueRowId) {
      return l10n.homeRowTrackerContinue(_trackerName);
    }
    if (id == newEpisodesRowId) return l10n.homeRowNewEpisodes;
    if (id.startsWith('section:')) return id.substring('section:'.length);
    final status = WatchStatus.values.asNameMap()[id.substring(
      'tracker:'.length,
    )];
    return status == null
        ? id
        : trackerStatusLabel(context, status, reading: _reading);
  }
}

/// A group label's slot in the arrangement (labels anchor, rows persist).
class _GroupTag {
  const _GroupTag._(this.group, this.isYours);
  const _GroupTag.yours() : this._('y', true);
  const _GroupTag.discover() : this._('d', false);

  final String group;
  final bool isYours;
}
