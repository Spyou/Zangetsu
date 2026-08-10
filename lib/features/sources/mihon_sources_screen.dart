import 'dart:io';
import 'package:watch_app/core/hive/safe_box.dart';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../core/di/injector.dart';
import '../../core/prefs/source_lang_prefs.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/mihon/mihon_manager.dart';
import '../../core/mihon/mihon_provider.dart';
import '../../core/mihon/mihon_update.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import 'source_language_sheet.dart';
import '../../core/ui/states.dart';
import 'mihon_repo_tab.dart'
    show kMihonReposBoxName, MihonAddRepoDialog, MihonRepoTab;
import 'sources_search_field.dart';

/// Dedicated Mihon (manga) ecosystem screen — Installed + Repositories in one
/// scroll. Structural twin of `AniyomiSourcesScreen`
/// (`lib/features/sources/aniyomi_sources_screen.dart`) — deliberately
/// duplicated rather than shared (spec Decision 3).
///
/// Unlike `AniyomiSourcesScreen`, this is phone-only. That screen carries a
/// full TV branch because it's reachable from both the phone and TV hub
/// views; the Mihon hub row (`ProvidersHubScreen`) is phone-only by spec, so
/// nothing ever routes here on TV and a TV branch would be dead code.
///
/// Mihon sources have NO enable/disable switch — a tap sets the source
/// active, matching the Aniyomi screen exactly.
class MihonSourcesScreen extends StatefulWidget {
  const MihonSourcesScreen({super.key});

  @override
  State<MihonSourcesScreen> createState() => _MihonSourcesScreenState();
}

class _MihonSourcesScreenState extends State<MihonSourcesScreen> {
  // ── Mihon repo state (moved-pattern twin of _AniyomiSourcesScreenState) ──
  List<String> _mihonRepoUrls = [];

  @override
  void initState() {
    super.initState();
    _loadMihonRepos();
  }

  Future<void> _loadMihonRepos() async {
    if (!Hive.isBoxOpen(kMihonReposBoxName)) {
      await openBoxSafely<String>(kMihonReposBoxName);
    }
    final box = Hive.box<String>(kMihonReposBoxName);
    if (mounted) setState(() => _mihonRepoUrls = box.values.toList());
  }

  Future<void> _addMihonRepo(String url) async {
    if (!Hive.isBoxOpen(kMihonReposBoxName)) {
      await openBoxSafely<String>(kMihonReposBoxName);
    }
    final box = Hive.box<String>(kMihonReposBoxName);
    if (box.values.contains(url)) return;
    await box.add(url);
    if (mounted) setState(() => _mihonRepoUrls = box.values.toList());
  }

  Future<void> _removeMihonRepo(String url) async {
    if (!Hive.isBoxOpen(kMihonReposBoxName)) return;
    final box = Hive.box<String>(kMihonReposBoxName);
    final key = box.toMap().entries
        .where((e) => e.value == url)
        .map((e) => e.key)
        .firstOrNull;
    if (key != null) await box.delete(key);
    if (mounted) setState(() => _mihonRepoUrls = box.values.toList());
  }

  /// Shows the add-repo dialog and, on a chosen URL, persists it directly.
  Future<void> _showAddMihonRepoDialog(BuildContext context) async {
    final Set<String> alreadyAdded = {};
    if (Hive.isBoxOpen(kMihonReposBoxName)) {
      alreadyAdded.addAll(Hive.box<String>(kMihonReposBoxName).values);
    }
    final url = await showDialog<String>(
      context: context,
      builder: (_) => MihonAddRepoDialog(alreadyAddedUrls: alreadyAdded),
    );
    if (url == null || url.isEmpty) return;
    await _addMihonRepo(url);
  }

  @override
  Widget build(BuildContext context) {
    return _MihonScreenPhoneView(
      repoUrls: _mihonRepoUrls,
      onAddRepo: () => _showAddMihonRepoDialog(context),
      onRemoveRepo: _removeMihonRepo,
    );
  }
}

// ---------------------------------------------------------------------------
// Phone view
// ---------------------------------------------------------------------------

class _MihonScreenPhoneView extends StatefulWidget {
  const _MihonScreenPhoneView({
    required this.repoUrls,
    required this.onAddRepo,
    required this.onRemoveRepo,
  });

  final List<String> repoUrls;
  final VoidCallback onAddRepo;
  final void Function(String url) onRemoveRepo;

  @override
  State<_MihonScreenPhoneView> createState() => _MihonScreenPhoneViewState();
}

class _MihonScreenPhoneViewState extends State<_MihonScreenPhoneView> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text('Mihon', style: AppText.barTitle),
          actions: [
            IconButton(
              tooltip: 'Languages',
              icon: const Icon(Icons.language_rounded),
              onPressed: () =>
                  showSourceLanguageSheet(context, sl<MangaLangPrefs>()),
            ),
          ],
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
          onPressed: widget.onAddRepo,
          icon: const Icon(Icons.add),
          label: Text(
            'Add Mihon repo',
            style: AppText.button.copyWith(color: Colors.white),
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SourcesSearchField(
                controller: _searchCtrl,
                onChanged: (q) => setState(() => _query = q),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                    children: [_MihonInstalledGroup(query: _query)],
                  ),
                  // MihonRepoTab brings its own scrollable ListView.builder +
                  // padding; wrapping it in another ListView gives the inner
                  // list unbounded height and it renders blank, so mount it
                  // directly (same reasoning as AniyomiRepoTab's host).
                  MihonRepoTab(
                    repoUrls: widget.repoUrls,
                    onRemoveRepo: widget.onRemoveRepo,
                    query: _query,
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

// ---------------------------------------------------------------------------
// Installed tab — Mihon group + source row. Structural twin of
// aniyomi_sources_screen.dart's _AniyomiInstalledGroup / _AniSourceRow.
// ---------------------------------------------------------------------------

class _MihonInstalledGroup extends StatefulWidget {
  const _MihonInstalledGroup({this.query = ''});

  final String query;

  @override
  State<_MihonInstalledGroup> createState() => _MihonInstalledGroupState();
}

class _MihonInstalledGroupState extends State<_MihonInstalledGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<MihonManager>(),
      builder: (context, _) {
        final query = widget.query;
        final sources = sl<MihonManager>()
            .all
            .where((p) => sourceSearchMatches(query, p.displayName, p.info.lang))
            .toList();
        if (sources.isEmpty) {
          return EmptyState(
            icon: Icons.menu_book_outlined,
            message: query.trim().isEmpty
                ? 'No Mihon sources installed.'
                : 'No installed sources match "${query.trim()}".',
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
                        'MIHON',
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
              // A live search forces the group open so matches are visible.
              child: !(_expanded || query.trim().isNotEmpty)
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
                              _MihonSourceRow(
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

/// Single Mihon source row in the Installed tab. Tapping makes it the active
/// source. No enable/disable switch — Mihon sources are always active.
///
/// [source] is typed [MihonProvider] directly rather than the generic
/// `BaseProvider` the Aniyomi twin uses: [MihonManager] already stores
/// `Map<String, MihonProvider>` (not the mixed-provider map `AniyomiManager`
/// stores), so there's no `is AniyomiProvider` narrowing to replicate here.
class _MihonSourceRow extends StatefulWidget {
  const _MihonSourceRow({
    required this.source,
    required this.activeId,
    this.updateLookupFn,
    this.applyUpdateFn,
  });

  final MihonProvider source;
  final String activeId;

  /// Test seam: overrides the live `MihonManager.updateFor` lookup. When
  /// non-null the button also skips the `AnimatedBuilder` so widget tests
  /// stay deterministic.
  final MihonUpdate? Function(String pkg)? updateLookupFn;

  /// Test seam: overrides the real install-from-repo apply flow.
  final Future<void> Function(MihonUpdate update)? applyUpdateFn;

  @override
  State<_MihonSourceRow> createState() => _MihonSourceRowState();
}

class _MihonSourceRowState extends State<_MihonSourceRow> {
  bool _hasSettings = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _checkSettings();
  }

  @override
  void didUpdateWidget(_MihonSourceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The element may be recycled for a different source when the list is
    // filtered/reordered (e.g. search) — re-query so the gear reflects the
    // source now shown rather than a stale cached result.
    if (oldWidget.source.sourceId != widget.source.sourceId) {
      _hasSettings = false;
      _checkSettings();
    }
  }

  Future<void> _checkSettings() async {
    final has = await MihonExtensionService().hasSourceSettings(widget.source.info.id);
    if (mounted) setState(() => _hasSettings = has);
  }

  Future<void> _openSettings() async {
    await MihonExtensionService().openSourceSettings(widget.source.info.id);
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

    final pkg = widget.source.pkg;

    if (Hive.isBoxOpen(MihonExtensionService.installedBoxName)) {
      final box = Hive.box<dynamic>(MihonExtensionService.installedBoxName);
      final apkPath = box.get(pkg) as String?;
      if (apkPath != null) {
        try {
          final f = File(apkPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      await box.delete(pkg);
    }

    sl<MihonManager>().removeWhere((p) => p.pkg == pkg);

    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Uninstalled $name')));
    }
  }

  Future<void> _applyUpdate(MihonUpdate update) async {
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

  Future<void> _defaultApplyUpdate(MihonUpdate update) async {
    // installFromRepo never throws — it returns an empty list on failure —
    // so a failed download must be surfaced here rather than silently
    // reported as a success that clears the update badge.
    final providers = await MihonExtensionService()
        .installFromRepo(update.entry, manager: sl<MihonManager>());
    if (providers.isEmpty) throw Exception('Update failed to install');
    sl<MihonManager>().clearUpdatesForPkg(update.pkg);
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.source;
    final active = source.sourceId == widget.activeId;
    final lang = source.info.lang;
    final nameColor = active ? AppColors.accent : AppColors.textPrimary;
    final lookup = widget.updateLookupFn ??
        (String pkg) => sl<MihonManager>().updateFor(pkg);

    Widget updateButton() {
      final update = lookup(source.pkg);
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
                    lang.isNotEmpty ? 'mihon • $lang' : 'mihon',
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            if (widget.updateLookupFn != null)
              updateButton()
            else
              AnimatedBuilder(
                animation: sl<MihonManager>(),
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

/// Test-only handle to the private installed Mihon row (mirrors
/// `aniyomi_sources_screen.dart`'s `debugAniSourceRow`).
@visibleForTesting
Widget debugMihonSourceRow({
  required MihonProvider source,
  required String activeId,
  MihonUpdate? Function(String pkg)? updateLookupFn,
  Future<void> Function(MihonUpdate update)? applyUpdateFn,
}) =>
    _MihonSourceRow(
      source: source,
      activeId: activeId,
      updateLookupFn: updateLookupFn,
      applyUpdateFn: applyUpdateFn,
    );
