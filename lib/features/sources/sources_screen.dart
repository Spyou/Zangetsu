import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/provider/provider_repo_registry.dart';
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
    _tab = TabController(length: 2, vsync: this);
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(state.notice!)));
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text('Sources', style: AppText.title),
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
            ],
          ),
        ),
        floatingActionButton: _index == 1
            ? FloatingActionButton.extended(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                onPressed: () => _showAddRepoDialog(context),
                icon: const Icon(Icons.add),
                label: Text('Add repo',
                    style: AppText.button.copyWith(color: Colors.white)),
              )
            : null,
        body: TabBarView(
          controller: _tab,
          children: const [
            _InstalledTab(),
            _ReposTab(),
          ],
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
        if (entries.isEmpty) {
          return const EmptyState(
            icon: Icons.dns_rounded,
            message: 'No providers installed.',
          );
        }
        // Group by origin repo. Bundled first, then repos alphabetically by
        // their resolved display name.
        final groups = <String, List<ProviderRegistryEntry>>{};
        for (final e in entries) {
          final key =
              e.originRepoUrl.isEmpty ? kBundledRepoUrl : e.originRepoUrl;
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
          itemCount: keys.length,
          itemBuilder: (_, i) {
            final key = keys[i];
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

class _InstalledGroup extends StatelessWidget {
  const _InstalledGroup({
    required this.title,
    required this.repoUrl,
    required this.entries,
  });

  final String title;
  final String repoUrl;
  final List<ProviderRegistryEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Text(
            title.toUpperCase(),
            style: AppText.overline.copyWith(color: AppColors.textTertiary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Container(
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
            child: Text('Cancel',
                style: AppText.body.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove',
                style: AppText.body.copyWith(color: AppColors.accent)),
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
    final meta = '${bundled ? 'built-in' : 'repo'} • v${entry.version}';
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
                Text(meta, style: AppText.caption),
              ],
            ),
          ),
          Switch.adaptive(
            value: entry.enabled,
            activeThumbColor: AppColors.accent,
            onChanged: (v) => context
                .read<SourcesBloc>()
                .add(SourceEnabledToggled(_key, enabled: v)),
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
      buildWhen: (a, b) =>
          a.repos != b.repos || a.installedKeys != b.installedKeys,
      builder: (context, state) {
        final all = state.repos;
        if (all.isEmpty) {
          return const EmptyState(
            icon: Icons.cloud_off_rounded,
            message: 'No repos added yet.\nTap "Add repo" to add one.',
          );
        }
        final installedKeys = state.installedKeys;
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          itemCount: all.length,
          itemBuilder: (_, i) =>
              _RepoSection(repo: all[i], installedKeys: installedKeys),
        );
      },
    );
  }
}

class _RepoSection extends StatelessWidget {
  const _RepoSection({required this.repo, required this.installedKeys});

  final ProviderRepo repo;
  final Set<String> installedKeys;

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
            child: Text('Cancel',
                style: AppText.body.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove',
                style: AppText.body.copyWith(color: AppColors.accent)),
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
                      Text('${repo.sources.length} sources',
                          style: AppText.caption),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert,
                      color: AppColors.textSecondary),
                  color: AppColors.surface2,
                  onSelected: (v) {
                    if (v == 'remove') _remove(context);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove repo',
                          style: AppText.body
                              .copyWith(color: AppColors.textPrimary)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (repo.sources.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('No sources in this repo yet.',
                  textAlign: TextAlign.center, style: AppText.caption),
            )
          else
            for (final source in repo.sources) ...[
              const Divider(
                  height: 0.5, thickness: 0.5, color: AppColors.hairline),
              _RepoSourceRow(
                repo: repo,
                source: source,
                installed: installedKeys.contains(
                    ProviderRegistry.providerKey(repo.url, source.id)),
              ),
            ],
        ],
      ),
    );
  }
}

class _RepoSourceRow extends StatelessWidget {
  const _RepoSourceRow({
    required this.repo,
    required this.source,
    required this.installed,
  });

  final ProviderRepo repo;
  final RepoSource source;
  final bool installed;

  String get _key => ProviderRegistry.providerKey(repo.url, source.id);

  void _install(BuildContext context) {
    context
        .read<SourcesBloc>()
        .add(SourceInstalled(repo: repo, source: source));
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
            child: Text('Cancel',
                style: AppText.body.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Uninstall',
                style: AppText.body.copyWith(color: AppColors.accent)),
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
                Text(
                  source.name,
                  style: AppText.headline.copyWith(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text('${source.lang} • v${source.version}',
                    style: AppText.caption),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (installed)
            OutlinedButton(
              onPressed: () => _uninstall(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                side: BorderSide(
                    color: AppColors.textSecondary.withValues(alpha: 0.4)),
                minimumSize: const Size(96, 36),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
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
                    borderRadius: BorderRadius.circular(8)),
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
    final error = await widget.bloc
        .addRepo(url, customName: name.isEmpty ? null : name);
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
            Text(_error!,
                style: AppText.caption.copyWith(color: AppColors.accent)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: Text('Cancel',
              style: AppText.body.copyWith(color: AppColors.textSecondary)),
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
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}
