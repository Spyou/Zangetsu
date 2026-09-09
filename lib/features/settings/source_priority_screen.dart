import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/playback/source_health_store.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/ui/source_switcher.dart' show categorizedSources;
import '../../core/zmode/source_order_prefs.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart' show candidatesForKind;

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

  /// Everything installed for [kind], in the user's saved order.
  List<({String id, String name})> _all(ZKind kind) => applySourceOrder(
    candidatesForKind(sl<SourceRepository>(), kind),
    _prefs.get(kind),
  );

  /// What Auto Resolve actually sweeps — the same call the resolver makes, so
  /// this screen can't show one thing while the sweep does another.
  List<({String id, String name})> _ordered(ZKind kind) =>
      activeSources(_all(kind), excluded: _prefs.excluded(kind));

  /// The rest, kept visible so turning one on is one tap rather than a hunt
  /// through the Sources screen.
  List<({String id, String name})> _off(ZKind kind) {
    final on = {for (final s in _ordered(kind)) s.id};
    return [
      for (final s in _all(kind))
        if (!on.contains(s.id)) s,
    ];
  }

  /// Writing an explicit list the first time someone touches this: until then
  /// the default (top [kDefaultActiveSources]) applies, and flipping one row
  /// has to pin down everything else as it currently stands or the rest would
  /// silently move too.
  Future<void> _setOn(ZKind kind, String id, {required bool on}) async {
    final off = {for (final s in _off(kind)) s.id};
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

  Widget _nameAndRepo(({String id, String name}) s, {required Color color}) {
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
      ],
    );
  }

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

  Future<void> _save(ZKind kind, List<({String id, String name})> list) =>
      _prefs.set(kind, [for (final s in list) s.id]);

  void _reorder(ZKind kind, int oldIndex, int newIndex) {
    final list = _sources;
    setState(() {
      final item = list.removeAt(oldIndex);
      list.insert(newIndex, item);
    });
    _save(kind, list);
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
    _save(kind, list);
  }

  Future<void> _reset(ZKind kind) async {
    await _prefs.clear(kind);
    await _prefs.setExcluded(kind, const {});
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
          // Advice at the top, where it can change what you do — not a rule
          // the app enforces behind your back. A number is given because
          // "fewer is faster" is useless without one, and it is phrased as a
          // suggestion because it IS one: every source is used until you say
          // otherwise.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Text(
              _isTv
                  ? 'Auto Resolve tries these in order until one has the '
                        'title. Around 10 good sources finds almost '
                        'everything — use the arrows to put yours first, and '
                        '✕ to stop it trying the ones you never use. Fewer '
                        'sources means Play starts sooner.'
                  : 'Auto Resolve tries these in order until one has the '
                        'title. Around 10 good sources finds almost '
                        'everything — drag yours to the top, and ✕ to stop it '
                        'trying the ones you never use. Fewer sources means '
                        'Play starts sooner.',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
          const SettingsSectionLabel('SOURCES', first: true),
          _section(ZKind.anime, _sources),
          if (_sourcesOff.isNotEmpty) ...[
            const SettingsSectionLabel('NOT USED BY AUTO RESOLVE'),
            _offSection(ZKind.anime, _sourcesOff),
          ],
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 6),
          child: Align(
            alignment: Alignment.centerRight,
            child: _isTv
                ? TvFocusable(
                    variant: TvFocusVariant.pill,
                    onTap: () => _reset(kind),
                    semanticLabel: 'Reset order',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Text(
                        'Reset order',
                        style: AppText.button.copyWith(
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                  )
                : TextButton(
                    onPressed: () => _reset(kind),
                    child: Text(
                      'Reset order',
                      style: AppText.button.copyWith(color: AppColors.accent),
                    ),
                  ),
          ),
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
          Expanded(child: _nameAndRepo(s, color: AppColors.textPrimary)),
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

  /// The switched-off list: no drag handles (order is meaningless here) and a
  /// + to put one back. Deliberately still on screen — a source that vanished
  /// with no way back is how people end up reinstalling things.
  Widget _offSection(ZKind kind, List<({String id, String name}) > list) {
    return SettingsCard(
      children: [
        for (final s in list)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Expanded(
                  child: _nameAndRepo(s, color: AppColors.textTertiary),
                ),
                if (_health(s.id) case final h?) _healthChip(h),
                const SizedBox(width: 4),
                _iconButton(
                  icon: Icons.add_rounded,
                  semanticLabel: 'Let Auto Resolve use ${_labelFor(s)} again',
                  onTap: () => _turnOn(kind, s.id),
                ),
              ],
            ),
          ),
      ],
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
          Expanded(child: _nameAndRepo(s, color: AppColors.textPrimary)),
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
