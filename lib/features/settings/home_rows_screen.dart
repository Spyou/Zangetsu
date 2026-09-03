import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/models/home_row.dart';
import '../../core/models/watch_status.dart';
import '../../core/mode/content_mode.dart';
import '../../core/mode/content_mode_cubit.dart';
import '../../core/repository/catalogue_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tracker/tracker_hub.dart';
import '../../core/ui/home_rows_prefs.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/zmode/home_layouts.dart';
import '../../core/zmode/metadata_provider_prefs.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart' show browseKindFor;
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';
import '../home/cubit/home_cubit.dart';
import '../home/cubit/home_rows_composer.dart';
import '../home/cubit/tracker_home_rows.dart';
import '../home/tracker_continue_section.dart';

/// The home-rows editor (Settings → Interface → Appearance → Customise Home,
/// phone only).
///
/// Opens on the layout the app is currently in, but every metadata layout is
/// reachable from the picker at the top — AniList, MyAnimeList, TMDB and Simkl
/// each keep their own arrangement per browse kind, and this screen used to
/// follow the mode bar silently, so Simkl's rows could only be arranged by
/// switching Home to Movies & TV first.
///
/// Rows keep their saved order verbatim; the two group labels ("From your
/// lists" / "Discover") are anchored above each group's first row, not fixed
/// slots, so dragging a row across groups is a real move. Every change saves
/// and bumps [HomeRowsPrefs.revision], which re-merges Home live behind this
/// screen. TV has no editor; it mirrors whatever was saved here.
class HomeRowsScreen extends StatefulWidget {
  const HomeRowsScreen({super.key});

  @override
  State<HomeRowsScreen> createState() => _HomeRowsScreenState();
}

class _HomeRowsScreenState extends State<HomeRowsScreen> {
  /// The layout being edited. Starts on the one the app is in, but the picker
  /// can move it anywhere — the screen used to follow the mode bar silently,
  /// so the only way to arrange Simkl's rows was to switch Home to Movies & TV
  /// first.
  late String _layoutKey;
  late bool _withTrackerRows;

  /// The browse kind of the layout being edited, or null when source-backed.
  ZKind? _kind;

  /// The metadata layout [_layoutKey] names, or null for a source-backed home
  /// (no fixed row list, so its sections come from the cubit instead).
  HomeLayout? _layoutInfo;

  /// The sanitized arrangement being edited, in saved order. False until there
  /// are sections to offer; editing without them could save a sectionless
  /// layout over a sectioned one.
  List<HomeRowEntry> _layout = const [];
  bool _ready = false;

  /// Only live while a source-backed Home's first load is in flight — see
  /// [initState]. Metadata layouts never need it; their rows are static.
  StreamSubscription<HomeState>? _sub;

  @override
  void initState() {
    super.initState();
    _kind = _browseKind();
    final providerPrefs = sl.isRegistered<MetadataProviderPrefs>()
        ? sl<MetadataProviderPrefs>()
        : null;
    _select(
      layoutKeyFor(
        sourceId: sl.isRegistered<CatalogueRepository>()
            ? sl<CatalogueRepository>().sourceId
            : '',
        zModeOn: _kind != null,
        browseKind: _kind,
        malPreferred: providerPrefs?.anime == AnimeProvider.mal,
        simklPreferred: providerPrefs?.video == VideoProvider.simkl,
      ),
    );
    // Only a source-backed home can be un-editable on arrival: its rows come
    // from a fetch that may still be running. Wait for it rather than sit on
    // the loading text until the screen is reopened.
    if (!_ready && sl.isRegistered<HomeCubit>()) {
      _sub = sl<HomeCubit>().stream.listen((s) {
        if (s.sections == null || !mounted) return;
        _sub?.cancel();
        _sub = null;
        setState(_reload);
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Point the editor at [key] and load its arrangement.
  void _select(String key) {
    _layoutKey = key;
    _layoutInfo = homeLayoutFor(key);
    _kind = _layoutInfo?.kind ?? _kind;
    _withTrackerRows = _canTrack(_kind);
    _reload();
  }

  /// Whether this layout can have list rows at all: its own provider has to be
  /// a tracker you're signed into that holds a library of this kind.
  ///
  /// TMDB is the case that forced it — a catalogue with no account, whose home
  /// used to borrow Simkl's lists under a heading that read as if they were
  /// TMDB's. The rule covers the rest too: signed out of AniList, the AniList
  /// home shows no list rows rather than quietly serving MAL's.
  bool _canTrack(ZKind? kind) {
    if (kind == null || !trackerRowsForKind(kind)) return false;
    if (!sl.isRegistered<TrackerHub>()) return false;
    return pickHomeTracker(
          sl<TrackerHub>(),
          kind,
          preferred: layoutTrackerName(_layoutKey),
        ) !=
        null;
  }

  /// Re-derive the arrangement from the same inputs the cubit merges with:
  /// the layout's Discover rows, the saved arrangement for this key, or the
  /// shipped default when none was saved.
  ///
  /// A metadata layout declares its rows statically, so any of the eight can
  /// be arranged without the app being in that mode — and a row whose fetch
  /// happened to fail can't quietly disappear from the editor and get dropped
  /// from the saved order. Only a source-backed home falls back to the live
  /// sections, since a source's rows are whatever it just returned.
  void _reload() {
    final info = _layoutInfo;
    List<String> sectionIds;
    if (info != null) {
      sectionIds = info.sectionIds;
    } else {
      final sections = sl.isRegistered<HomeCubit>()
          ? sl<HomeCubit>().state.sections
          : null;
      if (sections == null) return; // not loaded yet — nothing safe to edit
      sectionIds = [
        for (final s in providerRowSections(sections, isTv: false))
          'section:${s.title}',
      ];
    }
    final stored =
        HomeRowsPrefs.savedFor(_layoutKey) ??
        defaultLayout(
          sectionIds,
          withTrackerRows: _withTrackerRows,
          kind: _kind,
        );
    _layout = sanitizeLayout(stored, [
      localContinueRowId,
      if (_withTrackerRows) ...trackerRowIdsFor(_kind),
      ...sectionIds,
    ]);
    _ready = true;
  }

  /// Choose which arrangement to edit. Every metadata layout is offered, not
  /// just the ones your provider settings currently make live — arranging the
  /// one you are about to switch to shouldn't require switching first.
  Future<void> _pickLayout() async {
    final layouts = allHomeLayouts();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text(ctx.l10n.homeRowsLayout, style: AppText.headline),
                  ],
                ),
              ),
              const Divider(color: AppColors.hairline, height: 1),
              for (final l in layouts)
                ListTile(
                  onTap: () => Navigator.pop(ctx, l.key),
                  title: Text(
                    _layoutLabel(ctx, l),
                    style: AppText.body.copyWith(color: AppColors.textPrimary),
                  ),
                  trailing: l.key == _layoutKey
                      ? Icon(Icons.check, color: AppColors.accent)
                      : null,
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted || picked == _layoutKey) return;
    setState(() => _select(picked));
  }

  /// "AniList · Anime" — the provider decides the Discover rows, the kind
  /// decides which of its catalogues they come from.
  String _layoutLabel(BuildContext context, HomeLayout l) {
    final kind = switch (l.kind) {
      ZKind.manga => context.l10n.modeManga,
      ZKind.novel => context.l10n.modeNovel,
      ZKind.movie || ZKind.tv => context.l10n.moviesTV,
      ZKind.anime => context.l10n.modeAnime,
    };
    return '${l.provider} · $kind';
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

  /// Which tracker's name the list rows carry. They only exist when
  /// [_canTrack] found one, so this is that tracker; the layout's provider is
  /// a label of last resort for a build order that can't happen.
  String get _trackerName {
    final kind = _kind;
    final provider = layoutTrackerName(_layoutKey);
    if (kind == null || !sl.isRegistered<TrackerHub>()) {
      return provider ?? 'AniList';
    }
    final pick = pickHomeTracker(
      sl<TrackerHub>(),
      kind,
      preferred: provider,
    );
    return pick?.displayName ?? provider ?? 'AniList';
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
    final info = _layoutInfo;
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
                // SettingsCard brings its own 16px side margin; adding more
                // here would inset these cards past every other settings page.
                padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
                children: [
                  // Which arrangement is on screen, and the ONLY provider
                  // choice here: the layout's provider is also the tracker
                  // behind its list rows, so one control decides both.
                  if (info != null)
                    SettingsCard(
                      children: [
                        SettingsTile(
                          icon: Icons.dashboard_customize_outlined,
                          title: l10n.homeRowsLayout,
                          trailing: Text(
                            _layoutLabel(context, info),
                            style: AppText.caption,
                          ),
                          onTap: _pickLayout,
                        ),
                      ],
                    ),
                  // Cards are normally spaced by the section label between
                  // them; there is no heading to put here, just the gap.
                  if (info != null) const SizedBox(height: 14),
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
                    padding: const EdgeInsets.fromLTRB(28, 14, 22, 0),
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
    // Home swaps this row for ContinueReadingRow in a reading mode, so the
    // editor has to name the row Home will actually render.
    if (id == localContinueRowId) {
      return _reading ? l10n.continueReading : l10n.continueWatching;
    }
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
