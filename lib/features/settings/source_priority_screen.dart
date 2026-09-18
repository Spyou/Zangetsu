import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/source_switcher.dart' show categorizedSources;
import '../../core/zmode/source_order_prefs.dart';
import '../../core/zmode/source_score_store.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart'
    show candidatesForKind, sweepCandidates;

/// Why a source sits where it does, in one short line.
///
/// Dead outranks a good history on purpose: 47 past plays do not help an
/// episode that will not load today, and a row still reading "played 47 times"
/// is what would keep a broken source at the top of the sweep.
String reasonForSource({
  required int plays,
  required SourceHealth health,
  bool tried = true,
}) {
  // Dead first, whether or not it is being tried: naming the actual problem
  // beats "never used" on a source that is broken.
  if (health == SourceHealth.dead) return "hasn't worked recently";
  // A row below the cut, or one narrowed out, is not being tried — so it must
  // not say it is. Same rule as the failure sheet: never claim something was
  // attempted when it was not.
  if (!tried && plays == 0) return 'never used';
  if (plays == 0) return 'never used yet · trying it out';
  return 'played $plays times';
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
  late List<({String id, String name})> _sourcesOff = _off(ZKind.anime);
  late List<({String id, String name})> _sourcesUnavailable =
      _unavailable(ZKind.anime);

  /// Everything installed for [kind], in the user's saved order.
  List<({String id, String name})> _all(ZKind kind) => applySourceOrder(
    candidatesForKind(sl<SourceRepository>(), kind),
    _prefs.get(kind),
  );

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

  /// Sources the USER switched off, kept visible so turning one back on is one
  /// tap rather than a hunt through the Sources screen.
  ///
  /// Read straight from the exclude set rather than inferred as "everything
  /// not in [_ordered]". Those are different questions now that [_ordered] is
  /// narrowed: a source dropped for its language is absent from the sweep but
  /// nobody switched it off, and offering it a "turn back on" button that
  /// writes to an exclude set it was never in would do visibly nothing.
  List<({String id, String name})> _off(ZKind kind) {
    final excluded = _prefs.excluded(kind);
    return [
      for (final s in _all(kind))
        if (excluded.contains(s.id)) s,
    ];
  }

  /// Installed, not switched off, and still not swept — narrowed out by the
  /// language filter, or its runtime is not loaded.
  ///
  /// Its own group because the fix is different: this one is reached from
  /// Settings > Interface (language) or by the source loading, not by a toggle
  /// on this screen. Folding it in with [_off] would offer a button that
  /// cannot help.
  List<({String id, String name})> _unavailable(ZKind kind) {
    final swept = {for (final s in _ordered(kind)) s.id};
    final excluded = _prefs.excluded(kind);
    return [
      for (final s in _all(kind))
        if (!swept.contains(s.id) && !excluded.contains(s.id)) s,
    ];
  }

  /// Writing an explicit list the first time someone touches this: until then
  /// the default (top [kDefaultActiveSources]) applies, and flipping one row
  /// has to pin down everything else as it currently stands or the rest would
  /// silently move too.
  Future<void> _setOn(ZKind kind, String id, {required bool on}) async {
    final off = {..._prefs.excluded(kind)};
    if (on) {
      off.remove(id);
    } else {
      off.add(id);
    }
    await _prefs.setExcluded(kind, off);
    if (mounted) _refresh(kind);
  }

  void _refresh(ZKind kind) => setState(() {
    _sources = _ordered(ZKind.anime);
    _sourcesOff = _off(ZKind.anime);
    _sourcesUnavailable = _unavailable(ZKind.anime);
  });

  Future<void> _turnOff(ZKind kind, String id) => _setOn(kind, id, on: false);
  Future<void> _turnOn(ZKind kind, String id) => _setOn(kind, id, on: true);

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
  String _reasonFor(String id, {bool tried = true}) => reasonForSource(
        tried: tried,
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          // What the sweep actually does, said plainly at the top. This used
          // to be advice ("around 10 finds almost everything") that nothing
          // enforced; the cap is real now, so the line states it rather than
          // suggesting it.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Text(
              _hasPins
                  ? 'Auto Resolve tries the top $kAutoResolveCap and stops at '
                        'the first hit. The ones you dragged stay where you '
                        'put them; the rest are sorted by what has actually '
                        'worked for you.'
                  : 'Auto Resolve tries your best $kAutoResolveCap sources and '
                        'stops at the first one that has the title. Sorted by '
                        'what has actually worked for you — drag a source to '
                        'keep it on top.',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
          const SettingsSectionLabel('USED AUTOMATICALLY', first: true),
          _section(ZKind.anime, _sources.take(kAutoResolveCap).toList()),
          if (_sources.length > kAutoResolveCap) ...[
            const SettingsSectionLabel('NOT USED AUTOMATICALLY'),
            _belowCutSection(
              ZKind.anime,
              _sources.skip(kAutoResolveCap).toList(),
            ),
          ],
          if (_sourcesOff.isNotEmpty) ...[
            const SettingsSectionLabel('SWITCHED OFF'),
            _offSection(ZKind.anime, _sourcesOff),
          ],
          // Installed but not swept, and no toggle here will change that —
          // say which knob actually applies instead of offering one that
          // cannot help.
          if (_sourcesUnavailable.isNotEmpty) ...[
            const SettingsSectionLabel('NOT AVAILABLE RIGHT NOW'),
            _plainSection(
              ZKind.anime,
              _sourcesUnavailable,
              textColor: AppColors.textTertiary,
              icon: Icons.do_not_disturb_on_outlined,
              semanticLabel: (s) => '${_labelFor(s)} — not available right now',
              // Nothing on this screen can change it, so the row does not
              // pretend otherwise. The caption below says where the knob is.
              onTap: (_) {},
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Text(
                'These are installed but Auto Resolve is not trying them — '
                'their language is switched off in Settings > Interface, or '
                'the source has not loaded yet.',
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ),
          ],
          // Only once you have actually dragged something. Someone who never
          // takes over never sees a control for a mode they were never in.
          if (_hasPins)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 0, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Sources you dragged stay where you put them.',
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _resetButton(ZKind.anime),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 0),
            child: Text(
              'A title pinned to a source from its own Detail screen ignores '
              'this list and always uses that one.',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
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
    return SettingsCard(
      children: [
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
      ],
    );
  }

  Widget _row(ZKind kind, ({String id, String name}) s, int index) {
    final health = _health(s.id);
    return Padding(
      key: ValueKey(s.id),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
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
            child: _nameAndRepo(
              s,
              color: AppColors.textPrimary,
              reason: _reasonFor(s.id),
            ),
          ),
          if (health != null) _healthChip(health),
          const SizedBox(width: 4),
          _iconButton(
            icon: Icons.close_rounded,
            semanticLabel: 'Stop Auto Resolve using ${_labelFor(s)}',
            onTap: () => _turnOff(kind, s.id),
          ),
        ],
      ),
    );
  }

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

  /// A list with no drag handles or arrows — just each row's info and one
  /// action icon. Used below the cap and for switched-off sources: neither
  /// position is something a drag would move `_sources` to correctly, since
  /// `_reorder`/`_move` index straight into the full list and these rows sit
  /// at an offset from it.
  Widget _plainSection(
    ZKind kind,
    List<({String id, String name})> list, {
    required Color textColor,
    required IconData icon,
    required String Function(({String id, String name}) s) semanticLabel,
    required void Function(String id) onTap,
    bool showReason = false,
    IconData? leadingIcon,
    String Function(({String id, String name}) s)? leadingSemanticLabel,
    void Function(String id)? leadingOnTap,
  }) {
    return SettingsCard(
      children: [
        for (final s in list)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Expanded(
                  child: _nameAndRepo(
                    s,
                    color: textColor,
                    reason: showReason
                        ? _reasonFor(s.id, tried: false)
                        : null,
                  ),
                ),
                if (_health(s.id) case final h?) _healthChip(h),
                const SizedBox(width: 4),
                if (leadingIcon != null && leadingOnTap != null) ...[
                  _iconButton(
                    icon: leadingIcon,
                    semanticLabel: leadingSemanticLabel!(s),
                    onTap: () => leadingOnTap(s.id),
                  ),
                  const SizedBox(width: 2),
                ],
                _iconButton(
                  icon: icon,
                  semanticLabel: semanticLabel(s),
                  onTap: () => onTap(s.id),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Below the cap: still on, still eligible, just not among the top
  /// [kAutoResolveCap] — so the action is still ✕ (exclude), same as the
  /// ranked rows above, not the + that "switched off" gets.
  Widget _belowCutSection(ZKind kind, List<({String id, String name})> list) =>
      _plainSection(
        kind,
        list,
        textColor: AppColors.textPrimary,
        icon: Icons.close_rounded,
        semanticLabel: (s) => 'Stop Auto Resolve using ${_labelFor(s)}',
        onTap: (id) => _turnOff(kind, id),
        showReason: true,
        // Without this a source below the cut is stranded: these rows have no
        // drag handle (their index is offset from `_sources`, so a drag would
        // move the wrong row), and the ones you most want to promote are
        // exactly the ones down here.
        leadingIcon: Icons.vertical_align_top_rounded,
        leadingSemanticLabel: (s) => 'Move ${_labelFor(s)} to the top',
        leadingOnTap: (id) => _pinToTop(kind, id),
      );

  /// Put [id] first and pin it there, leaving every other pin in its order.
  ///
  /// One tap instead of dragging a row up twenty positions — and the only way
  /// a below-cut source can reach the sweep at all.
  Future<void> _pinToTop(ZKind kind, String id) async {
    final pins = [id, ..._prefs.get(kind).where((p) => p != id)];
    await _prefs.set(kind, pins);
    if (!mounted) return;
    _refresh(kind);
  }

  /// The switched-off list: no drag handles (order is meaningless here) and a
  /// + to put one back. Deliberately still on screen — a source that vanished
  /// with no way back is how people end up reinstalling things.
  Widget _offSection(ZKind kind, List<({String id, String name})> list) =>
      _plainSection(
        kind,
        list,
        textColor: AppColors.textTertiary,
        icon: Icons.add_rounded,
        semanticLabel: (s) => 'Let Auto Resolve use ${_labelFor(s)} again',
        onTap: (id) => _turnOn(kind, id),
      );

  /// TV row: up/down arrows instead of a drag handle — dragging isn't
  /// D-pad-drivable, so this is the only way to reorder with a remote.
  Widget _tvRow(
    ZKind kind,
    ({String id, String name}) s,
    int index,
    int count,
  ) {
    return Padding(
      key: ValueKey(s.id),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${index + 1}',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _nameAndRepo(
              s,
              color: AppColors.textPrimary,
              reason: _reasonFor(s.id),
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
          const SizedBox(width: 6),
          _iconButton(
            icon: Icons.close_rounded,
            semanticLabel: 'Stop Auto Resolve using ${_labelFor(s)}',
            onTap: () => _turnOff(kind, s.id),
          ),
        ],
      ),
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
