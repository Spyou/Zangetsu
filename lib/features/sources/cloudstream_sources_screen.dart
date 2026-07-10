import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/states.dart';
import 'source_settings_screen.dart';
import 'sources_screen.dart' show kRecommendedCsRepos;
import 'tv_recommended_cs_repos.dart';

/// Dedicated CloudStream ecosystem screen — Installed + Repositories in one
/// scroll. Self-contained: [CloudStreamManager] is an `sl` singleton, so the
/// whole body is observed via a single [ListenableBuilder] (no BlocProvider
/// needed).
///
/// Phone and TV share this file (`if (sl<AppMode>().isTv)`); every lifted
/// widget below is copied byte-identical from `sources_screen.dart` /
/// `sources_screen_tv.dart` — only the host screen around them is new.
/// CloudStream itself is Android-only: off Android [CloudStreamManager]'s
/// `repoGroups` is always empty, so both views fall through to their normal
/// empty state ("No CloudStream repos added yet") — matching the old tab.
class CloudStreamSourcesScreen extends StatelessWidget {
  const CloudStreamSourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<CloudStreamManager>(),
      builder: (context, _) {
        return sl<AppMode>().isTv ? const _CsTvView() : const _CsPhoneView();
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Phone view
// ---------------------------------------------------------------------------

class _CsPhoneView extends StatelessWidget {
  const _CsPhoneView();

  @override
  Widget build(BuildContext context) {
    final groups = sl<CloudStreamManager>().repoGroups;
    final installedGroups = groups.where((g) => g.sources.isNotEmpty);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('CloudStream', style: AppText.title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          Text(
            'INSTALLED'.toUpperCase(),
            style: AppText.overline.copyWith(color: AppColors.textTertiary),
          ),
          const SizedBox(height: 8),
          if (installedGroups.isEmpty)
            const EmptyState(
              icon: Icons.dns_rounded,
              message: 'No CloudStream sources installed.',
            )
          else
            BlocBuilder<ActiveSourceCubit, String>(
              builder: (context, activeId) => Column(
                children: [
                  for (final group in installedGroups)
                    _CsScreenInstalledGroup(group: group, activeId: activeId),
                ],
              ),
            ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Text(
                  'REPOSITORIES',
                  style: AppText.overline.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => _showAddCsRepoDialog(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add CS repo'),
                style: TextButton.styleFrom(foregroundColor: AppColors.accent),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (groups.isEmpty)
            const EmptyState(
              icon: Icons.cloud_outlined,
              message:
                  'No CloudStream repos added yet.\nTap "Add CS repo" to add one.',
            )
          else
            BlocBuilder<ActiveSourceCubit, String>(
              builder: (context, activeId) => Column(
                children: [
                  for (final group in groups)
                    _CsScreenRepoSection(group: group, activeId: activeId),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Prompts for a CloudStream repo URL, then adds it via [CloudStreamManager].
/// The dialog owns its own controller (see [_CsScreenAddRepoDialog]) —
/// building one here and disposing it right after the await crashes the exit
/// animation.
Future<void> _showAddCsRepoDialog(BuildContext context) async {
  final url = await showDialog<String>(
    context: context,
    builder: (_) => const _CsScreenAddRepoDialog(),
  );
  if (url == null || url.isEmpty) return;
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final count = await sl<CloudStreamManager>().addRepo(url);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            count == 0
                ? 'Repo added.'
                : 'Repo added — $count source${count == 1 ? '' : 's'} '
                      'available. Install the ones you want.',
          ),
        ),
      );
  } catch (e) {
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('Failed to add repo: $e')));
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen.dart — Installed-tab CloudStream group
// (renamed with a CsScreen prefix to avoid collisions with the originals).
// ---------------------------------------------------------------------------

/// Installed-tab CloudStream group — a chevron header with the UPPERCASE repo
/// [CsRepoGroup.name] and source count, over a surface card of shared
/// [_CsScreenSourceRow]s with 0.5 dividers. No delete here (matches the JS
/// Installed groups, which also have none).
class _CsScreenInstalledGroup extends StatefulWidget {
  const _CsScreenInstalledGroup({required this.group, required this.activeId});

  final CsRepoGroup group;
  final String activeId;

  @override
  State<_CsScreenInstalledGroup> createState() =>
      _CsScreenInstalledGroupState();
}

class _CsScreenInstalledGroupState extends State<_CsScreenInstalledGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final sources = widget.group.sources;
    final title = widget.group.name.isNotEmpty
        ? widget.group.name
        : 'CloudStream';
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
                    title.toUpperCase(),
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
              : Container(
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
                        _CsScreenSourceRow(
                          source: sources[i],
                          activeId: widget.activeId,
                        ),
                      ],
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }
}

/// The shared CloudStream source row — no leading icon, `Padding(16,8,6,8)`
/// over a name (accented + w600 when this is the active source, dimmed when
/// disabled) and a `'cloudstream'` meta line, then a [Switch.adaptive] for
/// enable/disable. The row body (not the switch) is tappable to make this the
/// active source. CloudStream has no per-source settings screen state beyond
/// the shared [SourceSettingsScreen], reached via the tune icon.
class _CsScreenSourceRow extends StatelessWidget {
  const _CsScreenSourceRow({required this.source, required this.activeId});

  final CloudStreamProvider source;
  final String activeId;

  @override
  Widget build(BuildContext context) {
    final manager = sl<CloudStreamManager>();
    final enabled = manager.isEnabled(source.sourceId);
    final active = source.sourceId == activeId;
    final nameColor = !enabled
        ? AppColors.textSecondary
        : active
        ? AppColors.accent
        : AppColors.textPrimary;
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
                  Text('cloudstream', style: AppText.caption),
                ],
              ),
            ),
            Switch.adaptive(
              value: enabled,
              activeThumbColor: AppColors.accent,
              onChanged: (v) => manager.setEnabled(source.sourceId, v),
            ),
            IconButton(
              tooltip: 'Source settings',
              icon: const Icon(Icons.tune_rounded, size: 20),
              color: AppColors.textSecondary,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SourceSettingsScreen(
                    sourceId: source.sourceId,
                    repoUrl: '',
                    displayName: source.displayName,
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

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen.dart — CloudStream tab repo section +
// helpers (renamed with a CsScreen prefix to avoid collisions).
// ---------------------------------------------------------------------------

/// Confirms then removes an entire CloudStream repo (its sources too) via
/// [CloudStreamManager.deleteRepo]; shows a "Removed" snackbar on success.
Future<void> _confirmDeleteCsRepo(BuildContext context, CsRepoGroup group) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('Remove repository?', style: AppText.headline),
      content: Text(
        'Remove this repository and its sources?',
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
            'Remove',
            style: AppText.body.copyWith(color: AppColors.accent),
          ),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await sl<CloudStreamManager>().deleteRepo(group.url);
  messenger
    ..clearSnackBars()
    ..showSnackBar(const SnackBar(content: Text('Removed')));
}

/// READ-ONLY check of a CloudStream repo for plugin updates via
/// [CloudStreamManager.checkRepoUpdates] (no download). Reports how many
/// updates are available; the accent badge + per-plugin "Update" buttons then
/// appear.
Future<void> _checkCsUpdates(BuildContext context, CsRepoGroup group) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..clearSnackBars()
    ..showSnackBar(const SnackBar(content: Text('Checking for updates…')));
  try {
    final updates = await sl<CloudStreamManager>().checkRepoUpdates(group.url);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            updates.isEmpty
                ? 'Up to date'
                : '${updates.length} update(s) available',
          ),
        ),
      );
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Check failed: $e')));
  }
}

/// Applies all available updates for a repo (re-download newer `.cs3`s) via
/// [CloudStreamManager.updateRepo], with progress + an honest result count.
Future<void> _applyCsRepoUpdates(BuildContext context, CsRepoGroup group) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..clearSnackBars()
    ..showSnackBar(const SnackBar(content: Text('Updating…')));
  try {
    final count = await sl<CloudStreamManager>().updateRepo(group.url);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            count == 0 ? 'Already up to date' : 'Updated $count source(s)',
          ),
        ),
      );
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
  }
}

/// A CloudStream repo card. Lists the repo's CATALOG — every plugin it
/// advertises — each with an Install / Installed (uninstall) button,
/// CloudStream-Extensions style. Adding a repo no longer installs anything;
/// the user installs the ones they want from here. The ⋮ menu checks for
/// updates / removes the repo. Activation + enable/disable of installed
/// sources lives in the Installed zone above.
///
/// For repos added before per-plugin install existed the catalog is fetched
/// lazily ([CloudStreamManager.ensureCatalog]); already-installed sources are
/// shown as Installed. The synthetic "Other" group (empty url) lists orphan
/// installed sources with an uninstall action and no ⋮ menu.
class _CsScreenRepoSection extends StatefulWidget {
  const _CsScreenRepoSection({required this.group, required this.activeId});

  final CsRepoGroup group;
  final String activeId;

  @override
  State<_CsScreenRepoSection> createState() => _CsScreenRepoSectionState();
}

class _CsScreenRepoSectionState extends State<_CsScreenRepoSection> {
  bool _expanded = true;
  bool _fetching = false;

  CsRepoGroup get group => widget.group;

  @override
  void initState() {
    super.initState();
    _maybeFetchCatalog();
  }

  @override
  void didUpdateWidget(covariant _CsScreenRepoSection old) {
    super.didUpdateWidget(old);
    if (old.group.url != group.url) _maybeFetchCatalog();
  }

  /// Lazily pull a repo's catalog if we don't have it yet (legacy repos).
  void _maybeFetchCatalog() {
    if (group.url.isEmpty || group.catalog.isNotEmpty || _fetching) return;
    setState(() => _fetching = true);
    sl<CloudStreamManager>().ensureCatalog(group.url).whenComplete(() {
      if (mounted) setState(() => _fetching = false);
    });
  }

  /// Pseudo-catalog for the synthetic "Other" group, built from orphan
  /// sources so they can still be uninstalled.
  List<CsPluginMeta> get _otherCatalog => [
    for (final s in group.sources)
      CsPluginMeta(
        internalName: (s.sourcePlugin ?? s.name).split('@').first,
        name: s.displayName,
        url: '',
        version: 0,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final manager = sl<CloudStreamManager>();
    final isOther = group.url.isEmpty;
    final updates = isOther ? const <CsUpdate>[] : manager.updatesFor(group.url);
    final catalog = isOther ? _otherCatalog : group.catalog;
    final installedCount = isOther
        ? group.sources.length
        : catalog
              .where(
                (p) => manager.isPluginInstalled(
                  p.internalName,
                  repoUrl: group.url,
                ),
              )
              .length;
    final title = group.name.isNotEmpty ? group.name : 'CloudStream';
    final owner = group.owner.isNotEmpty
        ? group.owner
        : (group.url.isNotEmpty ? group.url : null);
    final subtitle = isOther
        ? '${group.sources.length} installed'
        : (catalog.isEmpty
              ? (owner ?? 'cloudstream')
              : '$installedCount of ${catalog.length} installed'
                    '${owner != null ? ' • $owner' : ''}');
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _expanded = !_expanded),
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
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: AppText.headline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                style: AppText.caption.copyWith(
                                  color: AppColors.textTertiary,
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
                ),
                // "N updates" pill when this repo has installed plugins with a
                // newer version available (tap → apply all).
                if (updates.isNotEmpty)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _applyCsRepoUpdates(context, group),
                    child: Container(
                      margin: const EdgeInsets.only(right: 2),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        updates.length == 1
                            ? '1 update'
                            : '${updates.length} updates',
                        style: AppText.caption.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                // The synthetic "Other" group has an empty url and isn't a
                // real repo, so it gets no actions menu.
                if (group.url.isNotEmpty)
                  PopupMenuButton<String>(
                    icon: const Icon(
                      Icons.more_vert,
                      color: AppColors.textSecondary,
                    ),
                    color: AppColors.surface2,
                    onSelected: (v) {
                      if (v == 'check') _checkCsUpdates(context, group);
                      if (v == 'update') _applyCsRepoUpdates(context, group);
                      if (v == 'remove') _confirmDeleteCsRepo(context, group);
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'check',
                        child: Text(
                          'Check for updates',
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (updates.isNotEmpty)
                        PopupMenuItem(
                          value: 'update',
                          child: Text(
                            'Update all (${updates.length})',
                            style: AppText.body.copyWith(
                              color: AppColors.accent,
                            ),
                          ),
                        ),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text(
                          'Remove repo',
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          // Collapsible catalog list (install one by one).
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (catalog.isEmpty && _fetching)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.accent,
                              ),
                            ),
                          ),
                        )
                      else if (catalog.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'No installable sources found in this repo.',
                            textAlign: TextAlign.center,
                            style: AppText.caption,
                          ),
                        )
                      else
                        for (final plugin in catalog) ...[
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                          _CsScreenPluginRow(
                            plugin: plugin,
                            repoUrl: group.url,
                            installed: manager.isPluginInstalled(
                              plugin.internalName,
                              repoUrl: group.url,
                            ),
                            update: isOther
                                ? null
                                : manager.updateFor(
                                    plugin.internalName,
                                    group.url,
                                  ),
                          ),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen.dart — plugin catalog row.
// ---------------------------------------------------------------------------

class _CsScreenPluginRow extends StatefulWidget {
  const _CsScreenPluginRow({
    required this.plugin,
    required this.installed,
    this.repoUrl = '',
    this.update,
  });

  final CsPluginMeta plugin;
  final bool installed;

  /// The repository this catalog row belongs to — threaded into install /
  /// uninstall so the cache file is tagged per repo (same plugin, two repos →
  /// two independent installs).
  final String repoUrl;

  /// A newer version available for this (installed) plugin, or null. When
  /// set, the row shows an "Update" button instead of "Installed".
  final CsUpdate? update;

  @override
  State<_CsScreenPluginRow> createState() => _CsScreenPluginRowState();
}

class _CsScreenPluginRowState extends State<_CsScreenPluginRow> {
  bool _busy = false;

  String get _meta {
    final parts = <String>[
      if (widget.plugin.language != null) widget.plugin.language!,
      if (widget.plugin.tvTypes.isNotEmpty) widget.plugin.tvTypes.join(' / '),
    ];
    return parts.isEmpty ? 'cloudstream' : parts.join(' • ');
  }

  Future<void> _install() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await sl<CloudStreamManager>()
          .installPlugin(widget.plugin, repoUrl: widget.repoUrl);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text('Installed ${widget.plugin.name}')),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Install failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _update() async {
    final update = widget.update;
    if (update == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await sl<CloudStreamManager>()
          .updatePlugin(update, repoUrl: widget.repoUrl);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text('Updated ${widget.plugin.name}')),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Uninstall ${widget.plugin.name}?', style: AppText.headline),
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
    setState(() => _busy = true);
    try {
      await sl<CloudStreamManager>()
          .uninstallPlugin(widget.plugin, repoUrl: widget.repoUrl);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text('Uninstalled ${widget.plugin.name}')),
        );
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
    final installed = widget.installed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.plugin.name,
                  style: AppText.headline.copyWith(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(_meta, style: AppText.caption),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_busy)
            const SizedBox(
              width: 96,
              height: 36,
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                ),
              ),
            )
          else if (installed && widget.update != null)
            FilledButton(
              onPressed: _update,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                minimumSize: const Size(96, 36),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text('Update → v${widget.update!.onlineVersion}'),
            )
          else if (installed)
            OutlinedButton(
              onPressed: _uninstall,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                side: BorderSide(
                  color: AppColors.textSecondary.withValues(alpha: 0.4),
                ),
                minimumSize: const Size(96, 36),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Installed'),
            )
          else
            FilledButton(
              onPressed: _install,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                minimumSize: const Size(96, 36),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Install'),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen.dart — Add-CloudStream-repo dialog.
// ---------------------------------------------------------------------------

/// URL-input dialog for adding a CloudStream repo. Owns its own controller
/// and disposes it in [dispose] — the controller must outlive the dialog's
/// exit animation, so it cannot be created/disposed around an `await
/// showDialog`. Returns the trimmed URL via `Navigator.pop`, or null on
/// cancel.
class _CsScreenAddRepoDialog extends StatefulWidget {
  const _CsScreenAddRepoDialog();

  @override
  State<_CsScreenAddRepoDialog> createState() =>
      _CsScreenAddRepoDialogState();
}

class _CsScreenAddRepoDialogState extends State<_CsScreenAddRepoDialog> {
  final _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _urlCtrl.text.trim());

  /// A recommended repo row: name + blurb, with a one-tap "Add" that closes
  /// the dialog with the repo URL (same code path as a pasted one), or an
  /// "Added" marker when it's already in the user's list.
  Widget _recommendedTile(
    BuildContext context,
    ({String name, String desc, String url}) repo,
  ) {
    final added = sl<CloudStreamManager>().hasRepo(repo.url);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  repo.name,
                  style: AppText.body.copyWith(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(repo.desc, style: AppText.caption),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (added)
            Text(
              'Added',
              style: AppText.caption.copyWith(color: AppColors.textSecondary),
            )
          else
            OutlinedButton(
              onPressed: () => Navigator.pop(context, repo.url),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: BorderSide(
                  color: AppColors.accent.withValues(alpha: 0.6),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Add'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('Add CS repo', style: AppText.headline),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _urlCtrl,
              autofocus: false,
              keyboardType: TextInputType.url,
              cursorColor: AppColors.accent,
              style: AppText.body.copyWith(color: AppColors.textPrimary),
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Repo URL',
                hintText: 'https://.../repo.json',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "Paste a CloudStream repository URL — the app loads every "
              'source it lists.',
              style: AppText.caption,
            ),
            const SizedBox(height: 18),
            Text(
              'RECOMMENDED',
              style: AppText.caption.copyWith(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 4),
            for (final r in kRecommendedCsRepos) _recommendedTile(context, r),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            'Cancel',
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
          ),
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// TV view
// ---------------------------------------------------------------------------

class _CsTvView extends StatefulWidget {
  const _CsTvView();

  @override
  State<_CsTvView> createState() => _CsTvViewState();
}

class _CsTvViewState extends State<_CsTvView> {
  bool _installedExpanded = true;
  bool _reposExpanded = true;

  Future<void> _showAddCsRepoDialog() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _CsScreenTvAddRepoDialog(),
    );
    if (url == null || url.isEmpty) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await sl<CloudStreamManager>().addRepo(url);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              count == 0
                  ? 'Repo added.'
                  : 'Repo added — $count source${count == 1 ? '' : 's'} available.',
            ),
          ),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Failed to add repo: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  child: Text('CloudStream', style: AppText.largeTitle),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(40, 0, 40, 48),
                    children: [
                      // ── Installed ──────────────────────────────────────
                      _CsScreenTvSectionHeader(
                        title: 'Installed',
                        expanded: _installedExpanded,
                        autofocus: true,
                        onTap: () => setState(
                          () => _installedExpanded = !_installedExpanded,
                        ),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: _installedExpanded
                            ? const _CsScreenTvInstalledContent()
                            : const SizedBox(width: double.infinity),
                      ),
                      const SizedBox(height: 16),

                      // ── Repositories ───────────────────────────────────
                      _CsScreenTvSectionHeader(
                        title: 'Repositories',
                        expanded: _reposExpanded,
                        onTap: () =>
                            setState(() => _reposExpanded = !_reposExpanded),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: _reposExpanded
                            ? const _CsScreenTvReposContent()
                            : const SizedBox(width: double.infinity),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: _reposExpanded
                            ? Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: TvFocusable(
                                  scale: 1.0,
                                  onTap: _showAddCsRepoDialog,
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
                                          'Add CS repo',
                                          style: AppText.headline.copyWith(
                                            color: AppColors.accent,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox(width: double.infinity),
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

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen_tv.dart — shared section header.
// ---------------------------------------------------------------------------

class _CsScreenTvSectionHeader extends StatelessWidget {
  const _CsScreenTvSectionHeader({
    required this.title,
    required this.expanded,
    required this.onTap,
    this.autofocus = false,
  });

  final String title;
  final bool expanded;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      scale: 1.0,
      autofocus: autofocus,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Row(
          children: [
            AnimatedRotation(
              turns: expanded ? 0 : -0.25,
              duration: const Duration(milliseconds: 200),
              child: const Icon(
                Icons.expand_more,
                color: AppColors.textSecondary,
                size: 22,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              title.toUpperCase(),
              style: AppText.overline.copyWith(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim (CS-only slice) from sources_screen_tv.dart — Installed.
// Mirrors _TvCsInstalledGroupList / _TvCsInstalledGroup / _TvCsSourceRow.
// ---------------------------------------------------------------------------

class _CsScreenTvInstalledContent extends StatelessWidget {
  const _CsScreenTvInstalledContent();

  @override
  Widget build(BuildContext context) {
    final groups =
        sl<CloudStreamManager>().repoGroups.where((g) => g.sources.isNotEmpty);
    if (groups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: EmptyState(
          icon: Icons.dns_rounded,
          message: 'No CloudStream sources installed.',
        ),
      );
    }
    return BlocBuilder<ActiveSourceCubit, String>(
      builder: (context, activeId) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in groups)
            _CsScreenTvInstalledGroup(group: group, activeId: activeId),
        ],
      ),
    );
  }
}

class _CsScreenTvInstalledGroup extends StatefulWidget {
  const _CsScreenTvInstalledGroup({
    required this.group,
    required this.activeId,
  });
  final CsRepoGroup group;
  final String activeId;

  @override
  State<_CsScreenTvInstalledGroup> createState() =>
      _CsScreenTvInstalledGroupState();
}

class _CsScreenTvInstalledGroupState
    extends State<_CsScreenTvInstalledGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final title =
        widget.group.name.isNotEmpty ? widget.group.name : 'CloudStream';
    final sources = widget.group.sources;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Group header — OK toggles expand.
        TvFocusable(
          scale: 1.0,
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
                    title.toUpperCase(),
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
              : Container(
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
                        _CsScreenTvSourceRow(
                          source: sources[i],
                          activeId: widget.activeId,
                        ),
                      ],
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }
}

/// One installed CS source row: tapping the name sets the active source,
/// a separate TvFocusable toggles enable/disable, and a gear opens settings.
class _CsScreenTvSourceRow extends StatelessWidget {
  const _CsScreenTvSourceRow({
    required this.source,
    required this.activeId,
  });

  final CloudStreamProvider source;
  final String activeId;

  @override
  Widget build(BuildContext context) {
    final manager = sl<CloudStreamManager>();
    final enabled = manager.isEnabled(source.sourceId);
    final active = source.sourceId == activeId;
    final nameColor = !enabled
        ? AppColors.textSecondary
        : active
            ? AppColors.accent
            : AppColors.textPrimary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
      child: Row(
        children: [
          // Row body — OK sets this as the active source.
          Expanded(
            child: TvFocusable(
              scale: 1.0,
              onTap: () {
                context.read<ActiveSourceCubit>().setSource(source.sourceId);
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    SnackBar(
                      content: Text('Active source: ${source.displayName}'),
                    ),
                  );
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
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
                    Text('cloudstream', style: AppText.caption),
                  ],
                ),
              ),
            ),
          ),
          // Enable/disable toggle — OK flips the state.
          TvFocusable(
            scale: 1.0,
            onTap: () => manager.setEnabled(source.sourceId, !enabled),
            child: Switch.adaptive(
              value: enabled,
              activeThumbColor: AppColors.accent,
              onChanged: (v) => manager.setEnabled(source.sourceId, v),
            ),
          ),
          // Settings gear.
          TvFocusable(
            scale: 1.0,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SourceSettingsScreen(
                  sourceId: source.sourceId,
                  repoUrl: '',
                  displayName: source.displayName,
                ),
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(
                Icons.tune_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen_tv.dart — _TvCloudStreamContent (repo
// catalog list) + _TvCsRepoSection + _TvCsPluginRow.
// ---------------------------------------------------------------------------

class _CsScreenTvReposContent extends StatelessWidget {
  const _CsScreenTvReposContent();

  @override
  Widget build(BuildContext context) {
    final groups = sl<CloudStreamManager>().repoGroups;
    if (groups.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: EmptyState(
          icon: Icons.cloud_outlined,
          message:
              'No CloudStream repos added yet.\nPress "Add CS repo" to add one.',
        ),
      );
    }
    return BlocBuilder<ActiveSourceCubit, String>(
      builder: (context, activeId) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in groups)
            _CsScreenTvRepoSection(group: group, activeId: activeId),
        ],
      ),
    );
  }
}

class _CsScreenTvRepoSection extends StatefulWidget {
  const _CsScreenTvRepoSection({required this.group, required this.activeId});
  final CsRepoGroup group;
  final String activeId;

  @override
  State<_CsScreenTvRepoSection> createState() =>
      _CsScreenTvRepoSectionState();
}

class _CsScreenTvRepoSectionState extends State<_CsScreenTvRepoSection> {
  bool _expanded = true;
  bool _fetching = false;

  CsRepoGroup get group => widget.group;

  @override
  void initState() {
    super.initState();
    _maybeFetchCatalog();
  }

  @override
  void didUpdateWidget(covariant _CsScreenTvRepoSection old) {
    super.didUpdateWidget(old);
    if (old.group.url != group.url) _maybeFetchCatalog();
  }

  void _maybeFetchCatalog() {
    if (group.url.isEmpty || group.catalog.isNotEmpty || _fetching) return;
    setState(() => _fetching = true);
    sl<CloudStreamManager>().ensureCatalog(group.url).whenComplete(() {
      if (mounted) setState(() => _fetching = false);
    });
  }

  List<CsPluginMeta> get _otherCatalog => [
    for (final s in group.sources)
      CsPluginMeta(
        internalName: (s.sourcePlugin ?? s.name).split('@').first,
        name: s.displayName,
        url: '',
        version: 0,
      ),
  ];

  Future<void> _checkUpdates() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Checking for updates…')));
    try {
      final updates =
          await sl<CloudStreamManager>().checkRepoUpdates(group.url);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              updates.isEmpty
                  ? 'Up to date'
                  : '${updates.length} update(s) available',
            ),
          ),
        );
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Check failed: $e')));
    }
  }

  Future<void> _applyUpdates() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Updating…')));
    try {
      final count = await sl<CloudStreamManager>().updateRepo(group.url);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              count == 0 ? 'Already up to date' : 'Updated $count source(s)',
            ),
          ),
        );
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _removeRepo() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _csScreenTvConfirm(
      context,
      title: 'Remove repository?',
      body: 'Remove this repository and its sources?',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    await sl<CloudStreamManager>().deleteRepo(group.url);
    messenger
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Removed')));
  }

  @override
  Widget build(BuildContext context) {
    final manager = sl<CloudStreamManager>();
    final isOther = group.url.isEmpty;
    final updates = isOther ? const <CsUpdate>[] : manager.updatesFor(group.url);
    final catalog = isOther ? _otherCatalog : group.catalog;
    final title = group.name.isNotEmpty ? group.name : 'CloudStream';
    final installedCount = isOther
        ? group.sources.length
        : catalog
              .where(
                (p) => manager.isPluginInstalled(p.internalName,
                    repoUrl: group.url),
              )
              .length;
    final subtitle = isOther
        ? '${group.sources.length} installed'
        : (catalog.isEmpty
              ? (group.owner.isNotEmpty ? group.owner : 'cloudstream')
              : '$installedCount of ${catalog.length} installed'
                    '${group.owner.isNotEmpty ? ' • ${group.owner}' : ''}');

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Repo header row ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                // Expand/collapse toggle.
                TvFocusable(
                  scale: 1.0,
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
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
                      const SizedBox(width: 6),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: AppText.headline,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(subtitle,
                              style: AppText.caption.copyWith(
                                  color: AppColors.textTertiary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ],
                  ),
                ),
                // Update pill — apply all updates for this repo.
                if (updates.isNotEmpty)
                  TvFocusable(
                    scale: 1.0,
                    onTap: _applyUpdates,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        updates.length == 1
                            ? '1 update'
                            : '${updates.length} updates',
                        style: AppText.caption.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                // "Check updates" — real repos only (no synthetic Other group).
                if (group.url.isNotEmpty)
                  TvFocusable(
                    scale: 1.0,
                    onTap: _checkUpdates,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text('Check updates',
                          style: AppText.caption
                              .copyWith(color: AppColors.textSecondary)),
                    ),
                  ),
                // "Remove repo" — real repos only.
                if (group.url.isNotEmpty)
                  TvFocusable(
                    scale: 1.0,
                    onTap: _removeRepo,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text('Remove',
                          style: AppText.caption
                              .copyWith(color: AppColors.textSecondary)),
                    ),
                  ),
              ],
            ),
          ),
          // ── Collapsible plugin catalog ──────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (catalog.isEmpty && _fetching)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Center(
                            child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.accent,
                              ),
                            ),
                          ),
                        )
                      else if (catalog.isEmpty)
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'No installable sources found in this repo.',
                            textAlign: TextAlign.center,
                            style: AppText.caption,
                          ),
                        )
                      else
                        // Index-tracked loop so the first plugin row gets
                        // autofocus, routing D-pad there after repo is added.
                        for (final (idx, plugin) in catalog.indexed) ...[
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                          _CsScreenTvPluginRow(
                            plugin: plugin,
                            repoUrl: group.url,
                            installed: manager.isPluginInstalled(
                              plugin.internalName,
                              repoUrl: group.url,
                            ),
                            update: isOther
                                ? null
                                : manager.updateFor(
                                    plugin.internalName, group.url),
                            autofocus: idx == 0,
                          ),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// One CS plugin row with a single [TvFocusable] Install / Installed / Update
/// action button — mirrors the phone's [_CsScreenPluginRow].
/// [autofocus] should be true only for the first row so D-pad focus lands on
/// the Install button immediately after a repo is added and expanded.
class _CsScreenTvPluginRow extends StatefulWidget {
  const _CsScreenTvPluginRow({
    required this.plugin,
    required this.installed,
    this.repoUrl = '',
    this.update,
    this.autofocus = false,
  });

  final CsPluginMeta plugin;
  final bool installed;
  final String repoUrl;
  final CsUpdate? update;
  final bool autofocus;

  @override
  State<_CsScreenTvPluginRow> createState() => _CsScreenTvPluginRowState();
}

class _CsScreenTvPluginRowState extends State<_CsScreenTvPluginRow> {
  bool _busy = false;

  String get _meta {
    final parts = <String>[
      if (widget.plugin.language != null) widget.plugin.language!,
      if (widget.plugin.tvTypes.isNotEmpty)
        widget.plugin.tvTypes.join(' / '),
    ];
    return parts.isEmpty ? 'cloudstream' : parts.join(' • ');
  }

  Future<void> _install() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await sl<CloudStreamManager>()
          .installPlugin(widget.plugin, repoUrl: widget.repoUrl);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text('Installed ${widget.plugin.name}')),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Install failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _update() async {
    final upd = widget.update;
    if (upd == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await sl<CloudStreamManager>()
          .updatePlugin(upd, repoUrl: widget.repoUrl);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text('Updated ${widget.plugin.name}')),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall() async {
    final ok = await _csScreenTvConfirm(
      context,
      title: 'Uninstall ${widget.plugin.name}?',
      body: 'This removes the source from your installed list.',
      confirmLabel: 'Uninstall',
    );
    if (!ok) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await sl<CloudStreamManager>()
          .uninstallPlugin(widget.plugin, repoUrl: widget.repoUrl);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text('Uninstalled ${widget.plugin.name}')),
        );
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
    final installed = widget.installed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.plugin.name,
                  style: AppText.headline.copyWith(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(_meta, style: AppText.caption),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_busy)
            const SizedBox(
              width: 80,
              height: 36,
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                ),
              ),
            )
          else if (installed && widget.update != null)
            TvFocusable(
              scale: 1.0,
              autofocus: widget.autofocus,
              onTap: _update,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Update → v${widget.update!.onlineVersion}',
                  style: AppText.caption.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else if (installed)
            TvFocusable(
              scale: 1.0,
              autofocus: widget.autofocus,
              onTap: _uninstall,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: AppColors.textSecondary.withValues(alpha: 0.4),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Installed',
                  style: AppText.caption.copyWith(
                      color: AppColors.textSecondary),
                ),
              ),
            )
          else
            TvFocusable(
              scale: 1.0,
              autofocus: widget.autofocus,
              onTap: _install,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Install',
                  style: AppText.caption.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen_tv.dart — TV confirm dialog.
// ---------------------------------------------------------------------------

/// Shows a D-pad-navigable confirmation dialog. [Cancel] gets autofocus
/// (safe default). Returns true only when the user confirms.
Future<bool> _csScreenTvConfirm(
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
// Lifted verbatim from sources_screen_tv.dart — TV Add-CS-repo dialog.
// ---------------------------------------------------------------------------

class _CsScreenTvAddRepoDialog extends StatefulWidget {
  const _CsScreenTvAddRepoDialog();

  @override
  State<_CsScreenTvAddRepoDialog> createState() =>
      _CsScreenTvAddRepoDialogState();
}

class _CsScreenTvAddRepoDialogState extends State<_CsScreenTvAddRepoDialog> {
  final _urlCtrl = TextEditingController();
  // Not auto-focused: the dialog opens with the first RECOMMENDED repo
  // focused so a recommendation is one OK-press away and stays visible
  // (auto-raising the leanback IME would cover it). Focus the field + OK to
  // type a custom URL.
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
      title: Text('Add CS repo', style: AppText.headline),
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
                labelText: 'Repo URL',
                hintText: 'https://.../repo.json',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Paste a CloudStream repository URL.',
              style: AppText.caption,
            ),
            // Same recommended repos as the phone dialog, D-pad-focusable.
            TvRecommendedCsRepos(
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
