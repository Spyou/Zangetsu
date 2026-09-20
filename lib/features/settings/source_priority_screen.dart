import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/source_switcher.dart' show categorizedSources;
import '../../core/zmode/source_order_prefs.dart';
import '../../core/zmode/source_score_store.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart' show sweepCandidates;

/// Why a source sits where it does, in one short line.
///
/// Dead outranks a good history on purpose: 47 past plays do not help an
/// episode that will not load today, and a row still reading "played 47 times"
/// is what would keep a broken source at the top of the sweep.
String? reasonForSource({required int plays, required SourceHealth health}) {
  // Dead first: naming the actual fault is the one thing worth the line.
  if (health == SourceHealth.dead) return "hasn't worked recently";
  // A source nobody has played yet says NOTHING. On a fresh install that was
  // every row reading the same sentence — a wall of identical text carrying no
  // information, which buries the two or three rows that do state a fact.
  return plays == 0 ? null : 'played $plays times';
}

/// Reorder installed sources per content type. Auto Resolve (the default —
/// see `SourceMatcher`) sweeps sources in this order for every title that
/// hasn't been pinned to one by hand. Anime and Movies/TV get separate
/// orders: the same pool of sources serves both, but a source that's great
/// for one can return nothing for the other.
class SourcePriorityScreen extends StatefulWidget {
  const SourcePriorityScreen({super.key});

  @override
  State<SourcePriorityScreen> createState() => _SourcePriorityScreenState();
}

class _SourcePriorityScreenState extends State<SourcePriorityScreen> {
  SourceOrderPrefs get _prefs => sl<SourceOrderPrefs>();

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  // One list. Anime and Movies/TV share the same installed pool, so two
  // orders of the same sources was twice the list to keep straight for a
  // distinction most people don't draw.
  late List<({String id, String name})> _sources = _ordered(ZKind.anime);
  late int _cap = _prefs.cap(ZKind.anime);


  /// What Auto Resolve actually sweeps, in the order it walks them.
  ///
  /// This is [sweepCandidates] itself — the sweep's own function, uncapped —
  /// rather than a second implementation that agrees with it by inspection.
  /// The screen labels its first ten "USED AUTOMATICALLY", which is a claim
  /// that can be checked; ranking a wider pool here (one that still holds
  /// sources the language filter narrows out, and on TV sources whose runtime
  /// was never loaded) made that claim false for anyone with a language filter
  /// set. One function, one answer.
  List<({String id, String name})> _ordered(ZKind kind) =>
      sweepCandidates(kind);

  /// True once the user has pinned at least one source by dragging it.
  ///
  /// NOT a mode: pinned sources sit on top and everything below them stays
  /// auto-ranked. It only decides whether there is anything to undo.
  bool get _hasPins => _prefs.get(ZKind.anime).isNotEmpty;



  void _refresh(ZKind kind) => setState(() {
    _sources = _ordered(ZKind.anime);
    _cap = _prefs.cap(ZKind.anime);
  });


  /// A one-word verdict from the health store, when it has one worth showing.
  /// Silent for a healthy source: a row of green "ok" labels is noise, and the
  /// point of putting health here is to make the two or three worth moving
  /// stand out.
  /// id → (ecosystem-prefixed label, repo), the same two pieces the source
  /// picker and the "where to watch" list show.
  ///
  /// The bare display name is not enough to order a list by: "AniKoto" (a
  /// Zangetsu provider) and "Anikage" (a CloudStream plugin) read as the same
  /// word, and several repos ship a source of the same name — so you cannot
  /// tell which one you are moving. Built once; [categorizedSources] walks
  /// every installed manager and is not something to do per row.
  late final Map<String, ({String label, String? repo})> _tags = _readTags();

  Map<String, ({String label, String? repo})> _readTags() {
    final out = <String, ({String label, String? repo})>{};
    // Best-effort: a missing tag must never stop the screen from working.
    try {
      final b = categorizedSources();
      for (final r in [...b.anime, ...b.movies, ...b.nsfw, ...b.manga, ...b.novel]) {
        out[r.id] = (
          label: r.label,
          repo: (r.repo?.isNotEmpty ?? false) ? r.repo : null,
        );
      }
    } catch (_) {/* tags are cosmetic */}
    return out;
  }

  /// The name to show for [s] — the picker's label when we have it, so the
  /// two screens call the same source the same thing.
  String _labelFor(({String id, String name}) s) =>
      _tags[s.id]?.label ?? s.name;

  Widget _nameAndRepo(
    ({String id, String name}) s, {
    required Color color,
    String? reason,
  }) {
    final repo = _tags[s.id]?.repo;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _labelFor(s),
          style: AppText.body.copyWith(color: color, fontSize: 14.5),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (repo != null) ...[
          const SizedBox(height: 2),
          Text(
            repo,
            style: AppText.caption.copyWith(
              color: AppColors.textTertiary,
              fontSize: 11,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (reason != null) ...[
          const SizedBox(height: 2),
          Text(
            reason,
            style: AppText.caption.copyWith(
              color: AppColors.textTertiary,
              fontSize: 11,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }

  /// Why this source is where it is. The thing the old screen could not say,
  /// and the reason nobody knew which ten to keep.
  String? _reasonFor(String id) => reasonForSource(
    plays: sl<SourceScoreStore>().plays(id),
    health: sl<SourceHealthStore>().statusOf(id),
  );

  // Same two colours the Source Health screen uses, so a source reads the
  // same in both places.
  static const Color _red = Color(0xFFE05A47);
  static const Color _amber = Color(0xFFE0A33A);

  ({String label, Color color})? _health(String id) {
    if (!sl.isRegistered<SourceHealthStore>()) return null;
    final r = sl<SourceHealthStore>().recordOf(id);
    if (r == null) return null;
    return switch (sl<SourceHealthStore>().statusOf(id)) {
      SourceHealth.dead => (label: r.reason, color: _red),
      SourceHealth.slow => (label: 'slow', color: _amber),
      SourceHealth.ok => null,
    };
  }

  /// Pin everything down to [placedAt], and leave the rest auto-ranked.
  ///
  /// Saving the WHOLE list would pin all of it, which is what made one drag
  /// switch the entire screen to manual and stop ranking anything. Dropping a
  /// source at position N says "it goes after these N" — so those N are pinned
  /// with it, and everything below stays the app's to sort.
  Future<void> _save(
    ZKind kind,
    List<({String id, String name})> list, {
    required int placedAt,
  }) => _prefs.set(kind, [
    for (final s in list.take(placedAt + 1)) s.id,
  ]);

  void _reorder(ZKind kind, int oldIndex, int newIndex) {
    final list = _sources;
    setState(() {
      final item = list.removeAt(oldIndex);
      list.insert(newIndex, item);
    });
    _save(kind, list, placedAt: newIndex);
  }

  /// D-pad path: move one row up/down by exactly one slot. No off-by-one
  /// fixup needed (unlike drag reordering) since the move is always ±1.
  void _move(ZKind kind, int index, int delta) {
    final list = _sources;
    final target = index + delta;
    if (target < 0 || target >= list.length) return;
    setState(() {
      final item = list.removeAt(index);
      list.insert(target, item);
    });
    // Moving DOWN one slot places this row at `target`; moving UP places it
    // there too, but the row it swapped with now sits at `index` and is
    // equally placed, so pin through whichever is lower down the list.
    _save(kind, list, placedAt: target > index ? target : index);
  }

  /// Hand ranking back to the app.
  ///
  /// Clears the saved ORDER only. Which sources are switched off is a separate
  /// decision and stays put: someone who turned off three sources they never
  /// want tried has not asked for those back just because they want the
  /// remaining ones ranked automatically again.
  Future<void> _reset(ZKind kind) async {
    await _prefs.clear(kind);
    if (!mounted) return;
    _refresh(kind);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Source Priority'),
      // No horizontal padding here on purpose: SettingsCard carries its own
      // 16px margin, so anything given an inset by this ListView ends up 12px
      // further in than the cards and the whole screen looks ragged.
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 10, 0, 36),
        children: [
          _capControl(ZKind.anime),
          _section(ZKind.anime, _sources),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Text(
              'Drag a source to keep it where you put it. Everything else is '
              'sorted by what has actually worked for you. A title pinned from '
              'its own Detail screen ignores this list.',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
          if (_hasPins)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 0, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _resetButton(ZKind.anime),
              ),
            ),
        ],
      ),
    );
  }

  /// How many sources the sweep may try, and the one sentence explaining what
  /// that costs. The number is the whole setting — everything below it is just
  /// which sources, in what order.
  Widget _capControl(ZKind kind) => SettingsCard(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 0),
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    const TextSpan(text: 'Try the top '),
                    TextSpan(
                      text: '$_cap',
                      style: AppText.body.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    TextSpan(text: _cap == 1 ? ' source' : ' sources'),
                  ],
                ),
                style: AppText.body.copyWith(color: AppColors.textPrimary),
              ),
            ),
            if (_isTv) ...[
              _iconButton(
                icon: Icons.remove_rounded,
                semanticLabel: 'Try fewer sources',
                onTap: () => _setCap(kind, _cap - 1),
              ),
              _iconButton(
                icon: Icons.add_rounded,
                semanticLabel: 'Try more sources',
                onTap: () => _setCap(kind, _cap + 1),
              ),
            ],
          ],
        ),
      ),
      if (!_isTv)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
          child: Row(
            children: [
              // The ends of the range, said once, so nobody has to drag to
              // the edges to discover what they are.
              _sliderEnd('${SourceOrderPrefs.minCap}'),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 16,
                    ),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 8,
                    ),
                    activeTickMarkColor: Colors.transparent,
                    inactiveTickMarkColor: Colors.transparent,
                  ),
                  child: Slider(
                    value: _cap.toDouble(),
                    min: SourceOrderPrefs.minCap.toDouble(),
                    max: kAutoResolveCap.toDouble(),
                    divisions: kAutoResolveCap - SourceOrderPrefs.minCap,
                    onChanged: (v) => _setCap(kind, v.round()),
                  ),
                ),
              ),
              _sliderEnd('$kAutoResolveCap'),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 14),
        child: Text(
          'Auto Resolve tries them in order and stops at the first one that '
          'has the title. Fewer means Play starts sooner when nothing has it.',
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
      ),
    ],
  );

  Widget _sliderEnd(String n) => Text(
    n,
    style: AppText.caption.copyWith(
      color: AppColors.textTertiary,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );

  Future<void> _setCap(ZKind kind, int n) async {
    final next = n.clamp(SourceOrderPrefs.minCap, kAutoResolveCap);
    if (next == _cap) return;
    setState(() => _cap = next);
    await _prefs.setCap(kind, next);
  }

  /// TV gets the focus wrapper every other row on this screen already uses,
  /// with a plain label inside it — nesting a TextButton would put two tap
  /// handlers on one target and steal D-pad traversal, which is exactly what
  /// [SettingsTile] avoids by passing `onTap: null` under its focusable.
  Widget _resetButton(ZKind kind) {
    if (_isTv) {
      return TvListFocusable(
        onTap: () => _reset(kind),
        semanticLabel: 'Unpin all',
        child: ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              'Unpin all',
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ),
      );
    }
    return TextButton(
      onPressed: () => _reset(kind),
      child: const Text('Unpin all'),
    );
  }

  /// Same 16px gutter [SettingsCard] uses, so the tiles line up with the card
  /// above them instead of sitting 12px proud of it.
  Widget _listSurface(List<Widget> children) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _section(ZKind kind, List<({String id, String name})> list) {
    if (list.isEmpty) {
      return SettingsCard(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Center(
              child: Text(
                'No sources installed',
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ),
          ),
        ],
      );
    }
    return _listSurface([
        if (_isTv)
          Column(
            children: [
              for (var i = 0; i < list.length; i++)
                _tvRow(kind, list[i], i, list.length),
            ],
          )
        else
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: (oldIndex, newIndex) =>
                _reorder(kind, oldIndex, newIndex),
            children: [
              for (var i = 0; i < list.length; i++) _row(kind, list[i], i),
            ],
          ),
    ]);
  }

  Widget _row(ZKind kind, ({String id, String name}) s, int index) {
    final health = _health(s.id);
    final tried = index < _cap;
    // The cut is drawn UNDER the last tried row rather than as its own list
    // entry: a divider child inside a ReorderableListView is itself draggable
    // and shifts every index after it. Hanging it off the row keeps the list
    // one flat reorderable range, which is what lets a drag start anywhere —
    // including from below the cut, which is the whole point.
    final atCut = index == _cap - 1;
    return Column(
      key: ValueKey(s.id),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Each row is its own rounded tile with a gap under it, rather than a
        // band in one slab. A reorderable list should look like things you can
        // pick up; run them together and there is nothing to suggest a row is
        // a movable object at all.
        Container(
          decoration: BoxDecoration(
            color: tried
                ? AppColors.settingsCard
                : Color.lerp(AppColors.bg, AppColors.settingsCard, 0.45),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: tried ? AppColors.hairline : Colors.transparent,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
          child: Row(
            children: [
              // Number and handle read as one left gutter: the handle is what
              // you grab, the number is what you are moving it to.
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 18,
                        child: Text(
                          '${index + 1}',
                          textAlign: TextAlign.right,
                          style: AppText.caption.copyWith(
                            color: tried
                                ? AppColors.textSecondary
                                : AppColors.textTertiary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.drag_indicator_rounded,
                        size: 18,
                        color: AppColors.textTertiary.withValues(alpha: 0.7),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Opacity(
                  opacity: tried ? 1 : 0.45,
                  child: _nameAndRepo(
                    s,
                    color: AppColors.textPrimary,
                    reason: _reasonFor(s.id),
                  ),
                ),
              ),
              if (health != null) _healthChip(health),
              const SizedBox(width: 8),
            ],
          ),
        ),
        SizedBox(height: atCut ? 0 : 8),
        if (atCut) _cutLine(),
      ],
    );
  }

  Widget _cutLine() => Padding(
    padding: const EdgeInsets.fromLTRB(2, 10, 2, 10),
    child: Row(
      children: [
        Expanded(
          child: Divider(
            color: AppColors.accent.withValues(alpha: 0.35),
            height: 1,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            // Two things this line must not do. It must not imply these
            // sources are broken (they are fine — just past the number set
            // above), and it must not tell anyone to raise a number that is
            // already at its maximum. Dragging one up works at every setting,
            // so that is the action it names.
            'Auto Resolve stops here · drag one up to use it',
            style: AppText.caption.copyWith(
              color: AppColors.accent.withValues(alpha: 0.9),
              fontSize: 10.5,
              letterSpacing: 0.3,
            ),
          ),
        ),
        Expanded(
          child: Divider(
            color: AppColors.accent.withValues(alpha: 0.35),
            height: 1,
          ),
        ),
      ],
    ),
  );

  Widget _healthChip(({String label, Color color}) h) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: h.color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      h.label,
      style: AppText.caption.copyWith(color: h.color, fontSize: 11),
    ),
  );

  Widget _iconButton({
    required IconData icon,
    required String semanticLabel,
    required VoidCallback onTap,
  }) {
    final child = Padding(
      padding: const EdgeInsets.all(5),
      child: Icon(icon, size: 19, color: AppColors.textTertiary),
    );
    if (_isTv) {
      return TvFocusable(
        variant: TvFocusVariant.pill,
        scale: 1.0,
        semanticLabel: semanticLabel,
        onTap: onTap,
        child: child,
      );
    }
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: child,
      ),
    );
  }




  /// TV row: up/down arrows instead of a drag handle — dragging isn't
  /// D-pad-drivable, so this is the only way to reorder with a remote.
  Widget _tvRow(
    ZKind kind,
    ({String id, String name}) s,
    int index,
    int count,
  ) {
    // Same two signals the phone row carries. Without them the number at the
    // top of a TV screen is a setting with nothing on screen showing what it
    // did — which is the state this whole screen was rewritten to leave.
    final tried = index < _cap;
    final atCut = index == _cap - 1;
    return Column(
      key: ValueKey(s.id),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${index + 1}',
              style: AppText.caption.copyWith(
                color: tried
                    ? AppColors.textSecondary
                    : AppColors.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Opacity(
              opacity: tried ? 1 : 0.45,
              child: _nameAndRepo(
                s,
                color: AppColors.textPrimary,
                reason: _reasonFor(s.id),
              ),
            ),
          ),
          if (_health(s.id) case final h?) ...[_healthChip(h), const SizedBox(width: 4)],
          _tvMoveButton(
            icon: Icons.keyboard_arrow_up_rounded,
            enabled: index > 0,
            semanticLabel: 'Move ${_labelFor(s)} up',
            onTap: () => _move(kind, index, -1),
          ),
          const SizedBox(width: 6),
          _tvMoveButton(
            icon: Icons.keyboard_arrow_down_rounded,
            enabled: index < count - 1,
            semanticLabel: 'Move ${_labelFor(s)} down',
            onTap: () => _move(kind, index, 1),
          ),
        ],
      ),
        ),
        if (atCut) _cutLine(),
      ],
    );
  }

  Widget _tvMoveButton({
    required IconData icon,
    required bool enabled,
    required String semanticLabel,
    required VoidCallback onTap,
  }) {
    return TvFocusable(
      variant: TvFocusVariant.pill,
      scale: 1.0,
      semanticLabel: semanticLabel,
      onTap: enabled ? onTap : () {},
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(
          icon,
          size: 22,
          color: enabled ? AppColors.textPrimary : AppColors.textTertiary,
        ),
      ),
    );
  }
}
