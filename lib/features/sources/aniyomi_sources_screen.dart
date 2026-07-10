import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../core/aniyomi/aniyomi_extension_service.dart';
import '../../core/aniyomi/aniyomi_provider.dart';
import '../../core/aniyomi/aniyomi_repo.dart';
import '../../core/aniyomi/aniyomi_update.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/provider/base_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/states.dart';
import 'aniyomi_recommended_repos.dart';
import 'aniyomi_repo_tab.dart' show kAniyomiReposBoxName, AniyomiAddRepoDialog, AniyomiRepoTab;
import 'tv_recommended_aniyomi_repos.dart';

/// Dedicated Aniyomi ecosystem screen — Installed + Repositories in one
/// scroll. Stateful because it owns the Aniyomi-repos Hive-box state
/// (relocated from the old `_SourcesViewState`/`_TvSourcesViewState`).
///
/// Phone and TV share this file (`if (sl<AppMode>().isTv)`); every lifted
/// widget below is copied byte-identical from `sources_screen.dart` /
/// `sources_screen_tv.dart` / `aniyomi_repo_tab.dart` — only the host screen
/// around them is new. Aniyomi sources have NO enable/disable switch — a tap
/// sets the source active, matching the original screens exactly. Aniyomi
/// itself is Android-only: the TV view returns an early "not available"
/// screen off Android (mirroring the old TV screen's `Platform.isAndroid`
/// guard around this whole section); the phone view has no such guard,
/// matching the original phone tab.
class AniyomiSourcesScreen extends StatefulWidget {
  const AniyomiSourcesScreen({super.key});

  @override
  State<AniyomiSourcesScreen> createState() => _AniyomiSourcesScreenState();
}

class _AniyomiSourcesScreenState extends State<AniyomiSourcesScreen> {
  // ── Aniyomi repo state (moved from _SourcesViewState) ─────────────────────
  List<String> _aniyomiRepoUrls = [];

  @override
  void initState() {
    super.initState();
    _loadAniyomiRepos();
  }

  Future<void> _loadAniyomiRepos() async {
    if (!Hive.isBoxOpen(kAniyomiReposBoxName)) {
      await Hive.openBox<String>(kAniyomiReposBoxName);
    }
    final box = Hive.box<String>(kAniyomiReposBoxName);
    if (mounted) setState(() => _aniyomiRepoUrls = box.values.toList());
  }

  Future<void> _addAniyomiRepo(String url) async {
    if (!Hive.isBoxOpen(kAniyomiReposBoxName)) {
      await Hive.openBox<String>(kAniyomiReposBoxName);
    }
    final box = Hive.box<String>(kAniyomiReposBoxName);
    if (box.values.contains(url)) return;
    await box.add(url);
    if (mounted) setState(() => _aniyomiRepoUrls = box.values.toList());
  }

  Future<void> _removeAniyomiRepo(String url) async {
    if (!Hive.isBoxOpen(kAniyomiReposBoxName)) return;
    final box = Hive.box<String>(kAniyomiReposBoxName);
    final key = box.toMap().entries
        .where((e) => e.value == url)
        .map((e) => e.key)
        .firstOrNull;
    if (key != null) await box.delete(key);
    if (mounted) setState(() => _aniyomiRepoUrls = box.values.toList());
  }

  /// Shows the add-repo dialog and, on a chosen URL, persists it directly.
  /// This is a State method (not a free function) so it calls
  /// [_addAniyomiRepo] on `this`.
  Future<void> _showAddAniyomiRepoDialog(BuildContext context) async {
    final Set<String> alreadyAdded = {};
    if (Hive.isBoxOpen(kAniyomiReposBoxName)) {
      alreadyAdded.addAll(Hive.box<String>(kAniyomiReposBoxName).values);
    }
    final url = await showDialog<String>(
      context: context,
      builder: (_) => AniyomiAddRepoDialog(alreadyAddedUrls: alreadyAdded),
    );
    if (url == null || url.isEmpty) return;
    await _addAniyomiRepo(url);
  }

  Future<void> _showAddAniyomiRepoDialogTv() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _AniScreenTvAddRepoDialog(),
    );
    if (url == null || url.isEmpty) return;
    if (!mounted) return;
    await _addAniyomiRepo(url);
  }

  @override
  Widget build(BuildContext context) {
    return sl<AppMode>().isTv
        ? _AniScreenTvView(
            repoUrls: _aniyomiRepoUrls,
            onAddRepo: _showAddAniyomiRepoDialogTv,
            onRemoveRepo: _removeAniyomiRepo,
          )
        : _AniScreenPhoneView(
            repoUrls: _aniyomiRepoUrls,
            onAddRepo: () => _showAddAniyomiRepoDialog(context),
            onRemoveRepo: _removeAniyomiRepo,
          );
  }
}

// ---------------------------------------------------------------------------
// Phone view
// ---------------------------------------------------------------------------

class _AniScreenPhoneView extends StatelessWidget {
  const _AniScreenPhoneView({
    required this.repoUrls,
    required this.onAddRepo,
    required this.onRemoveRepo,
  });

  final List<String> repoUrls;
  final VoidCallback onAddRepo;
  final void Function(String url) onRemoveRepo;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text('Aniyomi', style: AppText.title),
          bottom: TabBar(
            indicatorColor: AppColors.accent,
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            labelStyle: AppText.headline,
            unselectedLabelStyle: AppText.headline,
            dividerHeight: 0,
            tabs: const [
              Tab(text: 'Installed'),
              Tab(text: 'Repositories'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          onPressed: onAddRepo,
          icon: const Icon(Icons.add),
          label: Text(
            'Add Aniyomi repo',
            style: AppText.button.copyWith(color: Colors.white),
          ),
        ),
        body: TabBarView(
          children: [
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: const [_AniyomiInstalledGroup()],
            ),
            ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                AniyomiRepoTab(repoUrls: repoUrls, onRemoveRepo: onRemoveRepo),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen.dart:1127-1470 — Installed-tab Aniyomi
// group + source row.
// ---------------------------------------------------------------------------

class _AniyomiInstalledGroup extends StatefulWidget {
  const _AniyomiInstalledGroup();

  @override
  State<_AniyomiInstalledGroup> createState() => _AniyomiInstalledGroupState();
}

class _AniyomiInstalledGroupState extends State<_AniyomiInstalledGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<AniyomiManager>(),
      builder: (context, _) {
        final sources = sl<AniyomiManager>().all;
        if (sources.isEmpty) {
          return const EmptyState(
            icon: Icons.extension_outlined,
            message: 'No Aniyomi sources installed.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: _expanded ? 0 : -0.25,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(
                        Icons.expand_more,
                        color: AppColors.textTertiary,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'ANIYOMI',
                        style: AppText.overline.copyWith(
                          color: AppColors.textTertiary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${sources.length}',
                      style: AppText.overline.copyWith(
                        color: AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: !_expanded
                  ? const SizedBox(width: double.infinity)
                  : BlocBuilder<ActiveSourceCubit, String>(
                      builder: (context, activeId) => Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < sources.length; i++) ...[
                              if (i > 0)
                                const Divider(
                                  height: 0.5,
                                  thickness: 0.5,
                                  color: AppColors.hairline,
                                ),
                              _AniSourceRow(
                                source: sources[i],
                                activeId: activeId,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 18),
          ],
        );
      },
    );
  }
}

/// Single Aniyomi source row in the Installed tab. Tapping makes it the active
/// source. No enable/disable switch — Aniyomi sources are always active.
class _AniSourceRow extends StatefulWidget {
  const _AniSourceRow({
    required this.source,
    required this.activeId,
    this.updateLookupFn,
    this.applyUpdateFn,
  });

  final BaseProvider source;
  final String activeId;

  /// Test seam: overrides the live `AniyomiManager.updateFor` lookup. When
  /// non-null the button also skips the `AnimatedBuilder` so widget tests
  /// stay deterministic.
  final AniyomiUpdate? Function(String pkg)? updateLookupFn;

  /// Test seam: overrides the real install-from-repo apply flow.
  final Future<void> Function(AniyomiUpdate update)? applyUpdateFn;

  @override
  State<_AniSourceRow> createState() => _AniSourceRowState();
}

class _AniSourceRowState extends State<_AniSourceRow> {
  bool _hasSettings = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _checkSettings();
  }

  @override
  void didUpdateWidget(_AniSourceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The element may be recycled for a different source when the list is
    // filtered/reordered (e.g. the NSFW toggle) — re-query so the gear
    // reflects the source now shown rather than a stale cached result.
    if (oldWidget.source.sourceId != widget.source.sourceId) {
      _hasSettings = false;
      _checkSettings();
    }
  }

  Future<void> _checkSettings() async {
    final src = widget.source;
    if (src is! AniyomiProvider) return;
    final has = await AniyomiExtensionService().hasSourceSettings(src.info.id);
    if (mounted) setState(() => _hasSettings = has);
  }

  Future<void> _openSettings() async {
    final src = widget.source;
    if (src is! AniyomiProvider) return;
    await AniyomiExtensionService().openSourceSettings(src.info.id);
  }

  /// Shows a confirm dialog then uninstalls the source.
  Future<void> _confirmUninstall(BuildContext context) async {
    final name = widget.source.displayName;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Uninstall $name?', style: AppText.headline),
        content: Text(
          'This removes the source from your installed list.',
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Uninstall',
              style: AppText.body.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final aniProvider =
        widget.source is AniyomiProvider ? widget.source as AniyomiProvider : null;
    final pkg = aniProvider?.info.pkg;

    const boxName = 'aniyomi_installed';
    if (pkg != null && Hive.isBoxOpen(boxName)) {
      final box = Hive.box<dynamic>(boxName);
      final apkPath = box.get(pkg) as String?;
      if (apkPath != null) {
        try {
          final f = File(apkPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      await box.delete(pkg);
    }

    if (pkg != null) {
      sl<AniyomiManager>().removeWhere(
        (p) => p is AniyomiProvider && p.info.pkg == pkg,
      );
    } else {
      sl<AniyomiManager>().removeWhere(
        (p) => p.sourceId == widget.source.sourceId,
      );
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Uninstalled $name')));
    }
  }

  Future<void> _applyUpdate(AniyomiUpdate update) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final apply = widget.applyUpdateFn ?? _defaultApplyUpdate;
      await apply(update);
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Updated ${update.name}')));
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _defaultApplyUpdate(AniyomiUpdate update) async {
    // installFromRepo never throws — it returns an empty list on failure —
    // so a failed download must be surfaced here rather than silently
    // reported as a success that clears the update badge.
    final providers = await AniyomiExtensionService()
        .installFromRepo(update.entry, manager: sl<AniyomiManager>());
    if (providers.isEmpty) throw Exception('Update failed to install');
    sl<AniyomiManager>().clearUpdatesForPkg(update.pkg);
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final active = source.sourceId == widget.activeId;
    final lang = source is AniyomiProvider ? source.info.lang : '';
    final nameColor = active ? AppColors.accent : AppColors.textPrimary;
    final aniProvider = source is AniyomiProvider ? source : null;
    final lookup = widget.updateLookupFn ??
        (String pkg) => sl<AniyomiManager>().updateFor(pkg);

    Widget updateButton() {
      final pkg = aniProvider?.info.pkg;
      final update = pkg == null ? null : lookup(pkg);
      if (update == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: FilledButton(
          onPressed: _busy ? null : () => _applyUpdate(update),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            elevation: 0,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text('Update → v${update.availableVersion}'),
        ),
      );
    }

    return InkWell(
      onTap: () {
        context.read<ActiveSourceCubit>().setSource(source.sourceId);
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(content: Text('Active source: ${source.displayName}')),
          );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    source.displayName,
                    style: AppText.headline.copyWith(
                      fontSize: 15,
                      color: nameColor,
                      fontWeight: active ? FontWeight.w600 : null,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    lang.isNotEmpty ? 'aniyomi • $lang' : 'aniyomi',
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            if (widget.updateLookupFn != null)
              updateButton()
            else
              AnimatedBuilder(
                animation: sl<AniyomiManager>(),
                builder: (_, _) => updateButton(),
              ),
            if (_hasSettings)
              IconButton(
                tooltip: 'Source settings',
                icon: const Icon(Icons.tune_rounded, size: 20),
                color: AppColors.textSecondary,
                onPressed: _openSettings,
              ),
            IconButton(
              tooltip: 'Uninstall',
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              color: AppColors.textSecondary,
              onPressed: () => _confirmUninstall(context),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TV view
// ---------------------------------------------------------------------------

class _AniScreenTvView extends StatefulWidget {
  const _AniScreenTvView({
    required this.repoUrls,
    required this.onAddRepo,
    required this.onRemoveRepo,
  });

  final List<String> repoUrls;
  final VoidCallback onAddRepo;
  final void Function(String url) onRemoveRepo;

  @override
  State<_AniScreenTvView> createState() => _AniScreenTvViewState();
}

class _AniScreenTvViewState extends State<_AniScreenTvView> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    // Aniyomi is Android-only (native extension host) — the old TV screen
    // gated this whole section behind Platform.isAndroid; preserve that here.
    if (!Platform.isAndroid) {
      return const Scaffold(
        backgroundColor: AppColors.bg,
        body: Stack(
          children: [
            Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Text(
                  "Aniyomi isn't available on this device.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            ),
            Positioned(top: 8, left: 8, child: TvBackButton()),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
                  child: Text('Aniyomi', style: AppText.largeTitle),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(40, 0, 40, 16),
                  child: Row(
                    children: [
                      _AniTvTabChip(
                        title: 'Installed',
                        selected: _tab == 0,
                        autofocus: true,
                        onTap: () => setState(() => _tab = 0),
                      ),
                      const SizedBox(width: 12),
                      _AniTvTabChip(
                        title: 'Repositories',
                        selected: _tab == 1,
                        onTap: () => setState(() => _tab = 1),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(40, 0, 40, 48),
                    children: _tab == 0
                        ? [
                            // ── Installed ────────────────────────────────
                            const _AniScreenTvInstalledContent(),
                          ]
                        : [
                            // ── Repositories ─────────────────────────────
                            _AniScreenTvContent(
                              repoUrls: widget.repoUrls,
                              onRemoveRepo: widget.onRemoveRepo,
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: TvFocusable(
                                scale: 1.0,
                                onTap: widget.onAddRepo,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 14,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.surface,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.add,
                                        color: AppColors.accent,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Add Aniyomi repo',
                                        style: AppText.headline.copyWith(
                                          color: AppColors.accent,
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
              ],
            ),
          ),
          // D-pad-focusable back button at top-left.
          const Positioned(
            top: 8,
            left: 8,
            child: SafeArea(child: TvBackButton()),
          ),
        ],
      ),
    );
  }
}

/// Focusable 2-tab switcher chip for TV — D-pad-friendly stand-in for a
/// [TabBar]. A selected chip shows the accent highlight even when it isn't
/// currently focused, so the active zone stays legible after focus moves
/// down into the content.
class _AniTvTabChip extends StatelessWidget {
  const _AniTvTabChip({
    required this.title,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      scale: 1.04,
      autofocus: autofocus,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.18)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.accent : Colors.transparent,
            width: 2,
          ),
        ),
        child: Text(
          title,
          style: AppText.headline.copyWith(
            color: selected ? AppColors.accent : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim (Aniyomi-only slice) from sources_screen_tv.dart —
// _TvAniyomiInstalledGroupList / _TvAniSourceRow (:550-692). Renders every
// installed Aniyomi source with the same tap-to-activate + ⚙ settings
// affordance as the phone row (the mixed old TV Installed tab used the
// lighter version without update/remove; this dedicated screen instead
// mirrors the phone's full _AniSourceRow so update + uninstall are reachable
// on TV too, matching the brief's "Installed extensions (tap = set active,
// ⚙, update, remove)" requirement).
// ---------------------------------------------------------------------------

class _AniScreenTvInstalledContent extends StatelessWidget {
  const _AniScreenTvInstalledContent();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<AniyomiManager>(),
      builder: (context, _) {
        final sources = sl<AniyomiManager>().all;
        if (sources.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.extension_outlined,
              message: 'No Aniyomi sources installed.',
            ),
          );
        }
        return BlocBuilder<ActiveSourceCubit, String>(
          builder: (context, activeId) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final source in sources)
                _AniScreenTvSourceRow(source: source, activeId: activeId),
            ],
          ),
        );
      },
    );
  }
}

class _AniScreenTvSourceRow extends StatefulWidget {
  const _AniScreenTvSourceRow({required this.source, required this.activeId});

  final BaseProvider source;
  final String activeId;

  @override
  State<_AniScreenTvSourceRow> createState() => _AniScreenTvSourceRowState();
}

class _AniScreenTvSourceRowState extends State<_AniScreenTvSourceRow> {
  bool _hasSettings = false;

  @override
  void initState() {
    super.initState();
    _checkSettings();
  }

  @override
  void didUpdateWidget(_AniScreenTvSourceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.sourceId != widget.source.sourceId) {
      _hasSettings = false;
      _checkSettings();
    }
  }

  Future<void> _checkSettings() async {
    final src = widget.source;
    if (src is! AniyomiProvider) return;
    final has = await AniyomiExtensionService().hasSourceSettings(src.info.id);
    if (mounted) setState(() => _hasSettings = has);
  }

  Future<void> _openSettings() async {
    final src = widget.source;
    if (src is! AniyomiProvider) return;
    await AniyomiExtensionService().openSourceSettings(src.info.id);
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final active = source.sourceId == widget.activeId;
    final lang = source is AniyomiProvider ? source.info.lang : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: TvFocusable(
        scale: 1.0,
        onTap: () {
          context.read<ActiveSourceCubit>().setSource(source.sourceId);
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(
                SnackBar(
                    content: Text('Active source: ${source.displayName}')),
              );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.displayName,
                      style: AppText.headline.copyWith(
                        color:
                            active ? AppColors.accent : AppColors.textPrimary,
                        fontWeight: active ? FontWeight.w600 : null,
                      ),
                    ),
                    if (lang.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'aniyomi • $lang',
                        style: AppText.caption,
                      ),
                    ],
                  ],
                ),
              ),
              if (_hasSettings)
                TvFocusable(
                  scale: 1.0,
                  onTap: _openSettings,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.tune_rounded,
                        size: 20, color: AppColors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen_tv.dart:2142-2495 — _TvAniyomiContent
// (repo list) + _TvAniyomiRepoSection + _TvAniyomiExtensionRow.
// ---------------------------------------------------------------------------

class _AniScreenTvContent extends StatelessWidget {
  const _AniScreenTvContent({
    required this.repoUrls,
    required this.onRemoveRepo,
  });

  final List<String> repoUrls;
  final void Function(String url) onRemoveRepo;

  Future<void> _removeRepo(BuildContext context, String url) async {
    final ok = await _aniScreenTvConfirm(
      context,
      title: 'Remove repo?',
      body:
          'Already-installed extensions stay installed. You can re-add the repo later.',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    onRemoveRepo(url);
  }

  @override
  Widget build(BuildContext context) {
    if (repoUrls.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: EmptyState(
          icon: Icons.extension_outlined,
          message:
              'No Aniyomi repos added yet.\nPress "Add Aniyomi repo" to add one.',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final url in repoUrls)
          _AniScreenTvRepoSection(
            url: url,
            onRemove: () => _removeRepo(context, url),
          ),
      ],
    );
  }
}

class _AniScreenTvRepoSection extends StatefulWidget {
  const _AniScreenTvRepoSection({required this.url, required this.onRemove});

  final String url;
  final VoidCallback onRemove;

  @override
  State<_AniScreenTvRepoSection> createState() =>
      _AniScreenTvRepoSectionState();
}

class _AniScreenTvRepoSectionState extends State<_AniScreenTvRepoSection> {
  List<AniyomiRepoEntry>? _entries;
  bool _fetching = true;
  String? _fetchError;
  bool _expanded = true;
  final Set<String> _installedPkgs = {};

  @override
  void initState() {
    super.initState();
    _loadInstalled();
    _fetch();
  }

  void _loadInstalled() {
    try {
      if (Hive.isBoxOpen(AniyomiExtensionService.installedBoxName)) {
        _installedPkgs.addAll(
            Hive.box<dynamic>(AniyomiExtensionService.installedBoxName)
                .keys
                .cast<String>());
      }
    } catch (_) {}
  }

  bool _isInstalled(String pkg) {
    if (_installedPkgs.contains(pkg)) return true;
    try {
      if (Hive.isBoxOpen(AniyomiExtensionService.installedBoxName)) {
        return Hive.box<dynamic>(AniyomiExtensionService.installedBoxName)
            .containsKey(pkg);
      }
    } catch (_) {}
    return false;
  }

  Future<void> _fetch() async {
    try {
      final entries = await AniyomiRepo.fetchIndex(widget.url);
      if (mounted) {
        setState(() {
          _entries = entries;
          _fetching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _fetchError = e.toString();
          _fetching = false;
        });
      }
    }
  }

  String get _repoDisplayName {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return widget.url;
    final segs = uri.pathSegments;
    if (segs.length >= 2) return '${segs[0]}/${segs[1]}';
    return uri.host;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries ?? [];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusable(
            scale: 1.0,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: _expanded ? 0 : -0.25,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(
                      Icons.expand_more,
                      color: AppColors.textSecondary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _repoDisplayName,
                      style: AppText.headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    _fetching
                        ? 'Loading…'
                        : _fetchError != null
                        ? 'Error'
                        : '${entries.length} ext.',
                    style: AppText.caption,
                  ),
                  const SizedBox(width: 12),
                  TvFocusable(
                    scale: 1.0,
                    onTap: widget.onRemove,
                    child: const Icon(
                      Icons.delete_outline,
                      color: AppColors.textSecondary,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded && !_fetching && entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                children: [
                  for (final entry in entries)
                    _AniScreenTvExtensionRow(
                      entry: entry,
                      installed: _isInstalled(entry.pkg),
                      onInstalled: () =>
                          setState(() => _installedPkgs.add(entry.pkg)),
                      onUninstalled: () =>
                          setState(() => _installedPkgs.remove(entry.pkg)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AniScreenTvExtensionRow extends StatefulWidget {
  const _AniScreenTvExtensionRow({
    required this.entry,
    required this.installed,
    required this.onInstalled,
    required this.onUninstalled,
  });

  final AniyomiRepoEntry entry;
  final bool installed;
  final VoidCallback onInstalled;
  final VoidCallback onUninstalled;

  @override
  State<_AniScreenTvExtensionRow> createState() =>
      _AniScreenTvExtensionRowState();
}

class _AniScreenTvExtensionRowState extends State<_AniScreenTvExtensionRow> {
  bool _busy = false;

  Future<void> _install() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final mgr = sl<AniyomiManager>();
      await AniyomiExtensionService().installFromRepo(widget.entry, manager: mgr);
      widget.onInstalled();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
            SnackBar(content: Text('Installed ${widget.entry.name}')));
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Install failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall() async {
    final ok = await _aniScreenTvConfirm(
      context,
      title: 'Uninstall ${widget.entry.name}?',
      body: 'This removes the extension from installed sources.',
      confirmLabel: 'Uninstall',
    );
    if (!ok) return;
    if (!mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (Hive.isBoxOpen(AniyomiExtensionService.installedBoxName)) {
        await Hive.box<dynamic>(AniyomiExtensionService.installedBoxName)
            .delete(widget.entry.pkg);
      }
      sl<AniyomiManager>().removeWhere(
        (p) => p is AniyomiProvider && p.info.pkg == widget.entry.pkg,
      );
      widget.onUninstalled();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
            SnackBar(content: Text('Uninstalled ${widget.entry.name}')));
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Uninstall failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final installed = widget.installed;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TvFocusable(
        scale: 1.0,
        onTap: installed ? _uninstall : _install,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            entry.name,
                            style: AppText.headline.copyWith(fontSize: 15),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (entry.nsfw) ...[
                          const SizedBox(width: 8),
                          const _AniScreenNsfwBadge(),
                        ],
                      ],
                    ),
                    if (entry.lang.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(entry.lang, style: AppText.caption),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (_busy)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                )
              else
                Text(
                  installed ? 'Installed' : 'Install',
                  style: AppText.caption.copyWith(
                    color:
                        installed ? AppColors.textSecondary : AppColors.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small shared widget: NSFW badge (mirrors sources_screen_tv.dart's local
// copy, renamed to avoid collision).
// ---------------------------------------------------------------------------

class _AniScreenNsfwBadge extends StatelessWidget {
  const _AniScreenNsfwBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
      ),
      child: Text(
        'NSFW',
        style: AppText.overline.copyWith(
          color: AppColors.accent,
          fontWeight: FontWeight.w700,
          fontSize: 9,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen_tv.dart:2532-2608 — shared TV confirm
// dialog helper.
// ---------------------------------------------------------------------------

Future<bool> _aniScreenTvConfirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(title, style: AppText.headline),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Text(
                body,
                style:
                    AppText.body.copyWith(color: AppColors.textSecondary),
              ),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Cancel — autofocused so D-pad lands here first.
                  TvFocusable(
                    scale: 1.0,
                    autofocus: true,
                    onTap: () => Navigator.pop(ctx, false),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      child: Text(
                        'Cancel',
                        style: AppText.body.copyWith(
                            color: AppColors.textSecondary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Confirm action.
                  TvFocusable(
                    scale: 1.0,
                    onTap: () => Navigator.pop(ctx, true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      child: Text(
                        confirmLabel,
                        style: AppText.body
                            .copyWith(color: AppColors.accent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return ok == true;
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen_tv.dart:2759-2842 — Add-Aniyomi-repo
// dialog (TV variant).
// ---------------------------------------------------------------------------

class _AniScreenTvAddRepoDialog extends StatefulWidget {
  const _AniScreenTvAddRepoDialog();

  @override
  State<_AniScreenTvAddRepoDialog> createState() =>
      _AniScreenTvAddRepoDialogState();
}

class _AniScreenTvAddRepoDialogState extends State<_AniScreenTvAddRepoDialog> {
  final _urlCtrl = TextEditingController();
  final _urlFocus = FocusNode();

  @override
  void dispose() {
    _urlCtrl.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _urlCtrl.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('Add Aniyomi repo', style: AppText.headline),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _urlCtrl,
              focusNode: _urlFocus,
              keyboardType: TextInputType.url,
              cursorColor: AppColors.accent,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Repo base URL',
                hintText: 'https://.../repo',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Paste the repo base URL — the app appends '
              '"/index.min.json" automatically.',
              style: AppText.caption,
            ),
            if (kRecommendedAniyomiRepos.isNotEmpty)
              TvRecommendedAniyomiRepos(
                onPick: (url) => Navigator.pop(context, url),
              ),
          ],
        ),
      ),
      actions: [
        TvFocusable(
          scale: 1.0,
          onTap: () => Navigator.of(context).pop(),
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ),
        TvFocusable(
          scale: 1.0,
          onTap: _submit,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: _submit,
            child: const Text('Add'),
          ),
        ),
      ],
    );
  }
}

/// Test-only handle to the private installed Aniyomi row (mirrors
/// `sources_screen.dart`'s `debugAniSourceRow`).
@visibleForTesting
Widget debugAniSourceRow({
  required BaseProvider source,
  required String activeId,
  AniyomiUpdate? Function(String pkg)? updateLookupFn,
  Future<void> Function(AniyomiUpdate update)? applyUpdateFn,
}) =>
    _AniSourceRow(
      source: source,
      activeId: activeId,
      updateLookupFn: updateLookupFn,
      applyUpdateFn: applyUpdateFn,
    );
