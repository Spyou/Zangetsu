import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/provider/provider_repo_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import 'bloc/sources_bloc.dart';
import 'bloc/sources_event.dart';
import 'bloc/sources_state.dart';
import 'source_settings_screen.dart';

/// Sources management — two tabs:
///   * Installed — every installed provider, grouped Built-in first then
///     one group per origin repo. Enable toggle + per-source settings +
///     remove (non-bundled).
///   * Repos — tracked manifest repos. Add via FAB; each repo lists its
///     sources with Install / Installed-Uninstall actions.
///
/// All source/repo data is owned by [SourcesBloc], which watches both Hive
/// boxes and re-emits on any change so both tabs stay in sync. The
/// TabController stays widget-local state — only the data lives in the bloc.
class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => SourcesBloc(
        registry: sl<ProviderRegistry>(),
        repos: sl<ProviderReposRegistry>(),
      ),
      child: const _SourcesView(),
    );
  }
}

class _SourcesView extends StatefulWidget {
  const _SourcesView();

  @override
  State<_SourcesView> createState() => _SourcesViewState();
}

class _SourcesViewState extends State<_SourcesView>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.addListener(() {
      if (_tab.indexIsChanging) return;
      if (_index != _tab.index) setState(() => _index = _tab.index);
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<SourcesBloc, SourcesState>(
      // Fire on every notice — including repeats — by listening to the
      // (notice, noticeSeq) pair, which changes even for identical text.
      listenWhen: (a, b) =>
          b.notice != null &&
          (a.notice != b.notice || a.noticeSeq != b.noticeSeq),
      listener: (context, state) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(state.notice!)));
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text('Providers', style: AppText.title),
          bottom: TabBar(
            controller: _tab,
            indicatorColor: AppColors.accent,
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            labelStyle: AppText.headline,
            unselectedLabelStyle: AppText.headline,
            dividerHeight: 0,
            tabs: const [
              Tab(text: 'Installed'),
              Tab(text: 'Repos'),
              Tab(text: 'CloudStream'),
            ],
          ),
        ),
        floatingActionButton: _index == 1
            ? FloatingActionButton.extended(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                onPressed: () => _showAddRepoDialog(context),
                icon: const Icon(Icons.add),
                label: Text(
                  'Add repo',
                  style: AppText.button.copyWith(color: Colors.white),
                ),
              )
            : _index == 2
            ? FloatingActionButton.extended(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                onPressed: () => _showAddCsRepoDialog(context),
                icon: const Icon(Icons.add),
                label: Text(
                  'Add CS repo',
                  style: AppText.button.copyWith(color: Colors.white),
                ),
              )
            : null,
        body: TabBarView(
          controller: _tab,
          children: const [_InstalledTab(), _ReposTab(), _CloudStreamTab()],
        ),
      ),
    );
  }
}

Future<void> _showAddRepoDialog(BuildContext context) {
  final bloc = context.read<SourcesBloc>();
  return showDialog<void>(
    context: context,
    builder: (_) => _AddRepoDialog(bloc: bloc),
  );
}

/// Prompts for a CloudStream repo URL, then adds it via [CloudStreamManager].
/// The dialog owns its own controller (see [_CsAddRepoDialog]) — building one
/// here and disposing it right after the await crashes the exit animation.
Future<void> _showAddCsRepoDialog(BuildContext context) async {
  final url = await showDialog<String>(
    context: context,
    builder: (_) => const _CsAddRepoDialog(),
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
// Installed tab
// ---------------------------------------------------------------------------

class _InstalledTab extends StatelessWidget {
  const _InstalledTab();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SourcesBloc, SourcesState>(
      buildWhen: (a, b) => a.installed != b.installed || a.repos != b.repos,
      builder: (context, state) {
        final entries = state.installed;
        final hasCs = sl<CloudStreamManager>().all.isNotEmpty;
        if (entries.isEmpty && !hasCs) {
          return const EmptyState(
            icon: Icons.dns_rounded,
            message: 'No providers installed.',
          );
        }
        // Group by origin repo. Bundled first, then repos alphabetically by
        // their resolved display name.
        final groups = <String, List<ProviderRegistryEntry>>{};
        for (final e in entries) {
          final key = e.originRepoUrl.isEmpty
              ? kBundledRepoUrl
              : e.originRepoUrl;
          groups.putIfAbsent(key, () => []).add(e);
        }
        final repoByUrl = {for (final r in state.repos) r.url: r};
        String nameFor(String repoUrl) {
          if (repoUrl == kBundledRepoUrl) return 'Built-in';
          final repo = repoByUrl[repoUrl];
          if (repo != null) return repo.displayName;
          // Fall back to a display name snapshotted on an entry, else the URL.
          final snap = groups[repoUrl]!
              .map((e) => e.displayName)
              .firstWhere((n) => n.isNotEmpty, orElse: () => repoUrl);
          return snap;
        }

        final keys = groups.keys.toList()
          ..sort((a, b) {
            if (a == kBundledRepoUrl) return -1;
            if (b == kBundledRepoUrl) return 1;
            return nameFor(a).toLowerCase().compareTo(nameFor(b).toLowerCase());
          });

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          // Index 0 is the CloudStream section (hides itself when empty); the
          // JS provider groups follow.
          itemCount: keys.length + 1,
          itemBuilder: (_, i) {
            if (i == 0) return const _CloudStreamGroup();
            final key = keys[i - 1];
            final items = groups[key]!
              ..sort((a, b) {
                final an = a.displayName.isNotEmpty ? a.displayName : a.name;
                final bn = b.displayName.isNotEmpty ? b.displayName : b.name;
                return an.toLowerCase().compareTo(bn.toLowerCase());
              });
            return _InstalledGroup(
              title: nameFor(key),
              repoUrl: key,
              entries: items,
            );
          },
        );
      },
    );
  }
}

class _InstalledGroup extends StatefulWidget {
  const _InstalledGroup({
    required this.title,
    required this.repoUrl,
    required this.entries,
  });

  final String title;
  final String repoUrl;
  final List<ProviderRegistryEntry> entries;

  @override
  State<_InstalledGroup> createState() => _InstalledGroupState();
}

class _InstalledGroupState extends State<_InstalledGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
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
                    widget.title.toUpperCase(),
                    style: AppText.overline.copyWith(
                      color: AppColors.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${entries.length}',
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
                      for (var i = 0; i < entries.length; i++) ...[
                        if (i > 0)
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                        _InstalledRow(entry: entries[i]),
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

class _InstalledRow extends StatelessWidget {
  const _InstalledRow({required this.entry});
  final ProviderRegistryEntry entry;

  String get _key =>
      ProviderRegistry.providerKey(entry.originRepoUrl, entry.name);

  Future<void> _confirmRemove(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final name = entry.displayName.isNotEmpty ? entry.displayName : entry.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Remove $name?', style: AppText.headline),
        content: Text(
          'The provider will be removed from your installed sources.',
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
    bloc.add(SourceUninstalled(_key, displayName: name));
  }

  @override
  Widget build(BuildContext context) {
    final bundled = entry.isBundled;
    final name = entry.displayName.isNotEmpty ? entry.displayName : entry.name;
    final state = context.read<SourcesBloc>().state;
    final hasUpdate = state.hasUpdate(_key);
    final newVersion = state.manifestVersions[_key];
    final meta = hasUpdate
        ? 'repo • v${entry.version} → v$newVersion'
        : '${bundled ? 'built-in' : 'repo'} • v${entry.version}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: AppText.headline.copyWith(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  style: AppText.caption.copyWith(
                    color: hasUpdate ? AppColors.accent : null,
                  ),
                ),
              ],
            ),
          ),
          if (hasUpdate)
            IconButton(
              tooltip: 'Update to v$newVersion',
              icon: const Icon(Icons.download_rounded, size: 20),
              color: AppColors.accent,
              onPressed: () =>
                  context.read<SourcesBloc>().add(SourceUpdated(_key)),
            ),
          Switch.adaptive(
            value: entry.enabled,
            activeThumbColor: AppColors.accent,
            onChanged: (v) => context.read<SourcesBloc>().add(
              SourceEnabledToggled(_key, enabled: v),
            ),
          ),
          IconButton(
            tooltip: 'Source settings',
            icon: const Icon(Icons.tune_rounded, size: 20),
            color: AppColors.textSecondary,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SourceSettingsScreen(
                  sourceId: entry.name,
                  repoUrl: entry.originRepoUrl,
                  displayName: name,
                ),
              ),
            ),
          ),
          if (!bundled)
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              color: AppColors.textSecondary,
              onPressed: () => _confirmRemove(context),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Repos tab
// ---------------------------------------------------------------------------

class _ReposTab extends StatelessWidget {
  const _ReposTab();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SourcesBloc, SourcesState>(
      buildWhen: (a, b) => a.repos != b.repos || a.installed != b.installed,
      builder: (context, state) {
        final all = state.repos;
        if (all.isEmpty) {
          return const EmptyState(
            icon: Icons.cloud_off_rounded,
            message: 'No repos added yet.\nTap "Add repo" to add one.',
          );
        }
        final installedKeys = state.installedKeys;
        final updatableKeys = state.updatableKeys;
        return RefreshIndicator(
          color: AppColors.accent,
          backgroundColor: AppColors.surface,
          onRefresh: () => context.read<SourcesBloc>().refreshAllRepos(),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemCount: all.length,
            itemBuilder: (_, i) => _RepoSection(
              repo: all[i],
              installedKeys: installedKeys,
              updatableKeys: updatableKeys,
            ),
          ),
        );
      },
    );
  }
}

class _RepoSection extends StatefulWidget {
  const _RepoSection({
    required this.repo,
    required this.installedKeys,
    required this.updatableKeys,
  });

  final ProviderRepo repo;
  final Set<String> installedKeys;
  final Set<String> updatableKeys;

  @override
  State<_RepoSection> createState() => _RepoSectionState();
}

class _RepoSectionState extends State<_RepoSection> {
  bool _expanded = true;

  ProviderRepo get repo => widget.repo;
  Set<String> get installedKeys => widget.installedKeys;
  Set<String> get updatableKeys => widget.updatableKeys;

  int get _updateCount => repo.sources
      .where(
        (s) =>
            updatableKeys.contains(ProviderRegistry.providerKey(repo.url, s.id)),
      )
      .length;

  Future<void> _remove(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Remove repo?', style: AppText.headline),
        content: Text(
          'Already-installed sources from "${repo.displayName}" stay '
          'installed. You can add the repo back later.',
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
    bloc.add(RepoRemoved(repo.url, displayName: repo.displayName));
  }

  @override
  Widget build(BuildContext context) {
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
                                repo.displayName,
                                style: AppText.headline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _updateCount > 0
                                    ? '${repo.sources.length} sources • $_updateCount update${_updateCount == 1 ? '' : 's'}'
                                    : '${repo.sources.length} sources',
                                style: AppText.caption.copyWith(
                                  color: _updateCount > 0
                                      ? AppColors.accent
                                      : AppColors.textTertiary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_updateCount > 0)
                  TextButton.icon(
                    onPressed: () => context.read<SourcesBloc>().add(
                      RepoUpdated(repo.url),
                    ),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text('Update all ($_updateCount)'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                    ),
                  ),
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert,
                    color: AppColors.textSecondary,
                  ),
                  color: AppColors.surface2,
                  onSelected: (v) {
                    if (v == 'remove') _remove(context);
                    if (v == 'update') {
                      context.read<SourcesBloc>().add(RepoUpdated(repo.url));
                    }
                    if (v == 'refresh') {
                      context.read<SourcesBloc>().add(RepoRefreshed(repo.url));
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'refresh',
                      child: Text(
                        'Check for updates',
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (_updateCount > 0)
                      PopupMenuItem(
                        value: 'update',
                        child: Text(
                          'Update all ($_updateCount)',
                          style: AppText.body.copyWith(color: AppColors.accent),
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
          // Collapsible source list.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (repo.sources.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'No sources in this repo yet.',
                            textAlign: TextAlign.center,
                            style: AppText.caption,
                          ),
                        )
                      else
                        // Hide NSFW sources unless the Privacy toggle is on.
                        for (final source in repo.sources.where(
                          (s) => !s.nsfw || sl<PlaybackPrefs>().nsfwSources,
                        )) ...[
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                          _RepoSourceRow(
                            repo: repo,
                            source: source,
                            installed: installedKeys.contains(
                              ProviderRegistry.providerKey(repo.url, source.id),
                            ),
                            hasUpdate: updatableKeys.contains(
                              ProviderRegistry.providerKey(repo.url, source.id),
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

/// Small "NSFW" chip shown next to a source flagged 18+ in its manifest.
class _NsfwBadge extends StatelessWidget {
  const _NsfwBadge();

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

class _RepoSourceRow extends StatelessWidget {
  const _RepoSourceRow({
    required this.repo,
    required this.source,
    required this.installed,
    required this.hasUpdate,
  });

  final ProviderRepo repo;
  final RepoSource source;
  final bool installed;
  final bool hasUpdate;

  String get _key => ProviderRegistry.providerKey(repo.url, source.id);

  void _install(BuildContext context) {
    context.read<SourcesBloc>().add(
      SourceInstalled(repo: repo, source: source),
    );
  }

  void _update(BuildContext context) {
    context.read<SourcesBloc>().add(SourceUpdated(_key));
  }

  Future<void> _uninstall(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Uninstall ${source.name}?', style: AppText.headline),
        content: Text(
          'The provider will be removed from your installed sources.',
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
    bloc.add(SourceUninstalled(_key, displayName: source.name));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
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
                        source.name,
                        style: AppText.headline.copyWith(fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (source.nsfw) ...[
                      const SizedBox(width: 8),
                      const _NsfwBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${source.lang} • v${source.version}',
                  style: AppText.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (installed && hasUpdate)
            FilledButton.icon(
              onPressed: () => _update(context),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Update'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                minimumSize: const Size(96, 36),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            )
          else if (installed)
            OutlinedButton(
              onPressed: () => _uninstall(context),
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
              onPressed: () => _install(context),
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
// Add-repo dialog
// ---------------------------------------------------------------------------

class _AddRepoDialog extends StatefulWidget {
  const _AddRepoDialog({required this.bloc});

  final SourcesBloc bloc;

  @override
  State<_AddRepoDialog> createState() => _AddRepoDialogState();
}

class _AddRepoDialogState extends State<_AddRepoDialog> {
  final _urlCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Enter a manifest URL.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final name = _nameCtrl.text.trim();
    // The bloc emits the "Added …" notice on success; on failure it returns
    // the message so we can render it inline and keep the dialog open.
    final error = await widget.bloc.addRepo(
      url,
      customName: name.isEmpty ? null : name,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _loading = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('Add repo', style: AppText.headline),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameCtrl,
            enabled: !_loading,
            cursorColor: AppColors.accent,
            style: AppText.body.copyWith(color: AppColors.textPrimary),
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Custom name (optional)',
              hintText: "Leave blank to use the repo's own name",
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            enabled: !_loading,
            autofocus: true,
            keyboardType: TextInputType.url,
            cursorColor: AppColors.accent,
            style: AppText.body.copyWith(color: AppColors.textPrimary),
            decoration: const InputDecoration(
              labelText: 'Manifest URL',
              hintText: 'https://.../index.json',
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "Paste the repo's index.json URL — the JSON file that lists "
            'every source in the repo, not a single provider .js URL.',
            style: AppText.caption,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
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
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}

/// CloudStream sources (loaded `.cs3` plugins) shown at the top of the Installed
/// tab. They live outside the JS [ProviderRegistry], so this reads them straight
/// from [CloudStreamManager] (a [ChangeNotifier], so it updates live after a
/// repo is added). Rendered as one collapsible group per [CsRepoGroup] that
/// mirrors the JS [_InstalledGroup] exactly (chevron + UPPERCASE repo name +
/// source count over a surface card of shared rows). Hidden when none.
class _CloudStreamGroup extends StatelessWidget {
  const _CloudStreamGroup();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<CloudStreamManager>(),
      builder: (context, _) {
        final groups = sl<CloudStreamManager>().repoGroups;
        if (groups.isEmpty) return const SizedBox.shrink();
        return BlocBuilder<ActiveSourceCubit, String>(
          builder: (context, activeId) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Only repos with at least one INSTALLED source belong here; a
              // freshly-added repo (catalog only, nothing installed) shows on
              // the CloudStream tab instead.
              for (final group in groups)
                if (group.sources.isNotEmpty)
                  _CsInstalledGroup(group: group, activeId: activeId),
            ],
          ),
        );
      },
    );
  }
}

/// Installed-tab CloudStream group — mirrors [_InstalledGroupState] exactly:
/// a chevron header with the UPPERCASE repo [CsRepoGroup.name] and source
/// count, over a surface card of shared [_CsSourceRow]s with 0.5 dividers. No
/// delete here (matches the JS Installed groups, which also have none).
class _CsInstalledGroup extends StatefulWidget {
  const _CsInstalledGroup({required this.group, required this.activeId});

  final CsRepoGroup group;
  final String activeId;

  @override
  State<_CsInstalledGroup> createState() => _CsInstalledGroupState();
}

class _CsInstalledGroupState extends State<_CsInstalledGroup> {
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
                        _CsSourceRow(
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

// ---------------------------------------------------------------------------
// CloudStream tab
// ---------------------------------------------------------------------------

/// Dedicated tab listing every loaded CloudStream source, grouped by origin
/// repo (owner / repo name) in collapsible sections. Reads straight from
/// [CloudStreamManager] (a [ChangeNotifier]) so it refreshes live after a repo
/// is added via the "Add CS repo" FAB. Tapping a row makes it the active source.
class _CloudStreamTab extends StatelessWidget {
  const _CloudStreamTab();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<CloudStreamManager>(),
      builder: (context, _) {
        final groups = sl<CloudStreamManager>().repoGroups;
        if (groups.isEmpty) {
          return const EmptyState(
            icon: Icons.cloud_outlined,
            message:
                'No CloudStream repos added yet.\nTap "Add CS repo" to add one.',
          );
        }
        return BlocBuilder<ActiveSourceCubit, String>(
          builder: (context, activeId) => ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            itemCount: groups.length,
            itemBuilder: (_, i) =>
                _CsRepoSection(group: groups[i], activeId: activeId),
          ),
        );
      },
    );
  }
}

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

/// Re-checks a CloudStream repo for updates (re-download newer `.cs3`s) via
/// [CloudStreamManager.updateRepo], with progress + result snackbars.
Future<void> _checkCsUpdates(BuildContext context, CsRepoGroup group) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..clearSnackBars()
    ..showSnackBar(const SnackBar(content: Text('Checking for updates…')));
  try {
    final count = await sl<CloudStreamManager>().updateRepo(group.url);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Updated — $count source(s)')));
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
  }
}

/// A CloudStream repo card on the CloudStream tab. Lists the repo's CATALOG —
/// every plugin it advertises — each with an Install / Installed (uninstall)
/// button, CloudStream-Extensions style. Adding a repo no longer installs
/// anything; the user installs the ones they want from here. The ⋮ menu checks
/// for updates / removes the repo. Activation + enable/disable of installed
/// sources lives on the Installed tab.
///
/// For repos added before per-plugin install existed the catalog is fetched
/// lazily ([CloudStreamManager.ensureCatalog]); already-installed sources are
/// shown as Installed. The synthetic "Other" group (empty url) lists orphan
/// installed sources with an uninstall action and no ⋮ menu.
class _CsRepoSection extends StatefulWidget {
  const _CsRepoSection({required this.group, required this.activeId});

  final CsRepoGroup group;
  final String activeId;

  @override
  State<_CsRepoSection> createState() => _CsRepoSectionState();
}

class _CsRepoSectionState extends State<_CsRepoSection> {
  bool _expanded = true;
  bool _fetching = false;

  CsRepoGroup get group => widget.group;

  @override
  void initState() {
    super.initState();
    _maybeFetchCatalog();
  }

  @override
  void didUpdateWidget(covariant _CsRepoSection old) {
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

  /// Pseudo-catalog for the synthetic "Other" group, built from orphan sources
  /// so they can still be uninstalled.
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
                // The synthetic "Other" group has an empty url and isn't a real
                // repo, so it gets no actions menu.
                if (group.url.isNotEmpty)
                  PopupMenuButton<String>(
                    icon: const Icon(
                      Icons.more_vert,
                      color: AppColors.textSecondary,
                    ),
                    color: AppColors.surface2,
                    onSelected: (v) {
                      if (v == 'update') _checkCsUpdates(context, group);
                      if (v == 'remove') _confirmDeleteCsRepo(context, group);
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'update',
                        child: Text(
                          'Check for updates',
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
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
                          _CsPluginRow(
                            plugin: plugin,
                            repoUrl: group.url,
                            installed: manager.isPluginInstalled(
                              plugin.internalName,
                              repoUrl: group.url,
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

/// One catalog plugin row: name + (language · types) and an Install / Installed
/// button. Install downloads + loads the `.cs3`; Installed taps to uninstall
/// (with a confirm). A spinner shows while the install/uninstall runs.
class _CsPluginRow extends StatefulWidget {
  const _CsPluginRow({
    required this.plugin,
    required this.installed,
    this.repoUrl = '',
  });

  final CsPluginMeta plugin;
  final bool installed;

  /// The repository this catalog row belongs to — threaded into install /
  /// uninstall so the cache file is tagged per repo (same plugin, two repos →
  /// two independent installs).
  final String repoUrl;

  @override
  State<_CsPluginRow> createState() => _CsPluginRowState();
}

class _CsPluginRowState extends State<_CsPluginRow> {
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

/// The shared CloudStream source row — mirrors the JS [_InstalledRow] exactly:
/// no leading icon, `Padding(16,8,6,8)` over a name (accented + w600 when this
/// is the active source, dimmed when disabled) and a `'cloudstream'` meta line,
/// then a [Switch.adaptive] for enable/disable. The row body (not the switch)
/// is tappable to make this the active source. CloudStream has no per-source
/// settings or delete, so there's no tune/delete button.
class _CsSourceRow extends StatelessWidget {
  const _CsSourceRow({required this.source, required this.activeId});

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
// Add-CloudStream-repo dialog
// ---------------------------------------------------------------------------

/// URL-input dialog for adding a CloudStream repo. Owns its own controller and
/// disposes it in [dispose] — the controller must outlive the dialog's exit
/// animation, so it cannot be created/disposed around an `await showDialog`.
/// Returns the trimmed URL via `Navigator.pop`, or null on cancel.
/// One-tap CloudStream repos surfaced in the "Add CS repo" dialog. Each is added
/// through the same [CloudStreamManager.addRepo] path as a manually pasted URL.
const List<({String name, String desc, String url})> _kRecommendedCsRepos = [
  (
    name: 'Phisher',
    desc: 'Large multi-source pack — anime, movies & series',
    url: 'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
  ),
  (
    name: 'CNC (All Languages)',
    desc: 'Multi-language movies, series & live TV',
    url: 'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json',
  ),
];

class _CsAddRepoDialog extends StatefulWidget {
  const _CsAddRepoDialog();

  @override
  State<_CsAddRepoDialog> createState() => _CsAddRepoDialogState();
}

class _CsAddRepoDialogState extends State<_CsAddRepoDialog> {
  final _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _urlCtrl.text.trim());

  /// A recommended repo row: name + blurb, with a one-tap "Add" that closes the
  /// dialog with the repo URL (same code path as a pasted one), or an "Added"
  /// marker when it's already in the user's list.
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
            for (final r in _kRecommendedCsRepos) _recommendedTile(context, r),
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
