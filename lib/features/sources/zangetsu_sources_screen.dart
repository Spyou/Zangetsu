import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/provider/provider_repo_registry.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/states.dart';
import 'bloc/sources_bloc.dart';
import 'bloc/sources_event.dart';
import 'bloc/sources_state.dart';
import 'source_settings_screen.dart';

/// Dedicated Zangetsu (JS provider) ecosystem screen — Installed and
/// Repositories as two tabs. Self-contained: creates its own [SourcesBloc]
/// so it works whether pushed standalone or from the Providers hub.
///
/// Phone and TV share this file (`if (sl<AppMode>().isTv)`); every lifted
/// widget below is copied byte-identical from `sources_screen.dart` /
/// `sources_screen_tv.dart` — only the host screen around them is new.
class ZangetsuSourcesScreen extends StatelessWidget {
  const ZangetsuSourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => SourcesBloc(
        registry: sl<ProviderRegistry>(),
        repos: sl<ProviderReposRegistry>(),
      ),
      child: sl<AppMode>().isTv
          ? const _ZTvView()
          : const _ZPhoneView(),
    );
  }
}

// ---------------------------------------------------------------------------
// Phone view
// ---------------------------------------------------------------------------

class _ZPhoneView extends StatelessWidget {
  const _ZPhoneView();

  @override
  Widget build(BuildContext context) {
    return BlocListener<SourcesBloc, SourcesState>(
      listenWhen: (a, b) =>
          b.notice != null &&
          (a.notice != b.notice || a.noticeSeq != b.noticeSeq),
      listener: (context, state) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(state.notice!)));
      },
      child: DefaultTabController(
        length: 2,
        child: Scaffold(
          backgroundColor: AppColors.bg,
          appBar: AppBar(
            title: Text('Zangetsu providers', style: AppText.title),
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
            onPressed: () => _showAddRepoDialog(context),
            icon: const Icon(Icons.add),
            label: Text(
              'Add Zangetsu repo',
              style: AppText.button.copyWith(color: Colors.white),
            ),
          ),
          body: TabBarView(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                children: const [_ZInstalledSection()],
              ),
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                children: const [_ZReposSection()],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showAddRepoDialog(BuildContext context) {
  final bloc = context.read<SourcesBloc>();
  return showDialog<void>(
    context: context,
    builder: (_) => _ZAddRepoDialog(bloc: bloc),
  );
}

/// Installed zone body for phone — the JS provider groups by origin repo.
/// Hides when empty with an empty-state line + hint.
class _ZInstalledSection extends StatelessWidget {
  const _ZInstalledSection();

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

        return Column(
          children: [
            for (final key in keys)
              _ZInstalledGroup(
                title: nameFor(key),
                repoUrl: key,
                entries: groups[key]!
                  ..sort((a, b) {
                    final an = a.displayName.isNotEmpty
                        ? a.displayName
                        : a.name;
                    final bn = b.displayName.isNotEmpty
                        ? b.displayName
                        : b.name;
                    return an.toLowerCase().compareTo(bn.toLowerCase());
                  }),
              ),
          ],
        );
      },
    );
  }
}

/// Repositories zone body for phone — repo rows with browse/install.
class _ZReposSection extends StatelessWidget {
  const _ZReposSection();

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
        return Column(
          children: [
            for (final repo in all)
              _ZRepoSection(
                repo: repo,
                installedKeys: installedKeys,
                updatableKeys: updatableKeys,
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen.dart — Installed tab widgets.
// (renamed with a Z prefix to avoid collisions with the originals)
// ---------------------------------------------------------------------------

class _ZInstalledGroup extends StatefulWidget {
  const _ZInstalledGroup({
    required this.title,
    required this.repoUrl,
    required this.entries,
  });

  final String title;
  final String repoUrl;
  final List<ProviderRegistryEntry> entries;

  @override
  State<_ZInstalledGroup> createState() => _ZInstalledGroupState();
}

class _ZInstalledGroupState extends State<_ZInstalledGroup> {
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
                        _ZInstalledRow(entry: entries[i]),
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

class _ZInstalledRow extends StatelessWidget {
  const _ZInstalledRow({required this.entry});
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
// Lifted verbatim from sources_screen.dart — Repos tab widgets.
// ---------------------------------------------------------------------------

class _ZRepoSection extends StatefulWidget {
  const _ZRepoSection({
    required this.repo,
    required this.installedKeys,
    required this.updatableKeys,
  });

  final ProviderRepo repo;
  final Set<String> installedKeys;
  final Set<String> updatableKeys;

  @override
  State<_ZRepoSection> createState() => _ZRepoSectionState();
}

class _ZRepoSectionState extends State<_ZRepoSection> {
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
                          _ZRepoSourceRow(
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
class _ZNsfwBadge extends StatelessWidget {
  const _ZNsfwBadge();

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

class _ZRepoSourceRow extends StatelessWidget {
  const _ZRepoSourceRow({
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
                      const _ZNsfwBadge(),
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
// Lifted verbatim from sources_screen.dart — Add-repo dialog.
// ---------------------------------------------------------------------------

class _ZAddRepoDialog extends StatefulWidget {
  const _ZAddRepoDialog({required this.bloc});

  final SourcesBloc bloc;

  @override
  State<_ZAddRepoDialog> createState() => _ZAddRepoDialogState();
}

class _ZAddRepoDialogState extends State<_ZAddRepoDialog> {
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

// ---------------------------------------------------------------------------
// TV view
// ---------------------------------------------------------------------------

class _ZTvView extends StatefulWidget {
  const _ZTvView();

  @override
  State<_ZTvView> createState() => _ZTvViewState();
}

class _ZTvViewState extends State<_ZTvView> {
  int _tab = 0;

  Future<void> _showAddRepoDialog() {
    final bloc = context.read<SourcesBloc>();
    return showDialog<void>(
      context: context,
      builder: (_) => _ZTvAddRepoDialog(bloc: bloc),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<SourcesBloc, SourcesState>(
      listenWhen: (a, b) =>
          b.notice != null &&
          (a.notice != b.notice || a.noticeSeq != b.noticeSeq),
      listener: (context, state) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(state.notice!)));
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
                    child: Text('Zangetsu providers', style: AppText.largeTitle),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(40, 0, 40, 16),
                    child: Row(
                      children: [
                        _ZTvTabChip(
                          title: 'Installed',
                          selected: _tab == 0,
                          autofocus: true,
                          onTap: () => setState(() => _tab = 0),
                        ),
                        const SizedBox(width: 12),
                        _ZTvTabChip(
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
                              // ── Installed ────────────────────────────
                              const _ZTvInstalledContent(),
                            ]
                          : [
                              // ── Repositories ──────────────────────────
                              const _ZTvReposContent(),
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: TvFocusable(
                                  scale: 1.0,
                                  onTap: _showAddRepoDialog,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                      vertical: 14,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.surface,
                                      borderRadius:
                                          BorderRadius.circular(10),
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
                                          'Add repo',
                                          style: AppText.headline
                                              .copyWith(
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
      ),
    );
  }
}

/// Focusable 2-tab switcher chip for TV — D-pad-friendly stand-in for a
/// [TabBar]. A selected chip shows the accent highlight even when it isn't
/// currently focused, so the active zone stays legible after focus moves
/// down into the content.
class _ZTvTabChip extends StatelessWidget {
  const _ZTvTabChip({
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
// Lifted verbatim (JS-only slice) from sources_screen_tv.dart — Installed.
// ---------------------------------------------------------------------------

class _ZTvInstalledContent extends StatelessWidget {
  const _ZTvInstalledContent();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SourcesBloc, SourcesState>(
      buildWhen: (a, b) => a.installed != b.installed || a.repos != b.repos,
      builder: (context, state) {
        final entries = state.installed;
        if (entries.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.dns_rounded,
              message: 'No providers installed.',
            ),
          );
        }

        // Group JS providers by origin repo (same logic as phone).
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

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // JS provider groups.
            for (final key in keys)
              _ZTvInstalledGroup(
                title: nameFor(key),
                entries: groups[key]!
                  ..sort((a, b) {
                    final an =
                        a.displayName.isNotEmpty ? a.displayName : a.name;
                    final bn =
                        b.displayName.isNotEmpty ? b.displayName : b.name;
                    return an.toLowerCase().compareTo(bn.toLowerCase());
                  }),
                state: state,
              ),
          ],
        );
      },
    );
  }
}

class _ZTvInstalledGroup extends StatefulWidget {
  const _ZTvInstalledGroup({
    required this.title,
    required this.entries,
    required this.state,
  });

  final String title;
  final List<ProviderRegistryEntry> entries;
  final SourcesState state;

  @override
  State<_ZTvInstalledGroup> createState() => _ZTvInstalledGroupState();
}

class _ZTvInstalledGroupState extends State<_ZTvInstalledGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
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
                        _ZTvInstalledRow(
                          entry: entries[i],
                          state: widget.state,
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

/// One installed JS provider row. Each action (update / enable toggle /
/// settings / remove) is an independent [TvFocusable] so the D-pad can
/// reach them independently.
class _ZTvInstalledRow extends StatelessWidget {
  const _ZTvInstalledRow({
    required this.entry,
    required this.state,
  });

  final ProviderRegistryEntry entry;
  final SourcesState state;

  String get _key =>
      ProviderRegistry.providerKey(entry.originRepoUrl, entry.name);

  Future<void> _confirmRemove(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final name =
        entry.displayName.isNotEmpty ? entry.displayName : entry.name;
    final ok = await _zTvConfirm(
      context,
      title: 'Remove $name?',
      body: 'The provider will be removed from your installed sources.',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    bloc.add(SourceUninstalled(_key, displayName: name));
  }

  @override
  Widget build(BuildContext context) {
    final bundled = entry.isBundled;
    final name =
        entry.displayName.isNotEmpty ? entry.displayName : entry.name;
    final hasUpdate = state.hasUpdate(_key);
    final newVersion = state.manifestVersions[_key];
    final meta = hasUpdate
        ? 'repo • v${entry.version} → v$newVersion'
        : '${bundled ? 'built-in' : 'repo'} • v${entry.version}';

    return _ZRowFocusHalo(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
        child: Row(
          children: [
            // Source name + meta (non-interactive label).
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
            // Update button — present only when a newer version is available.
            if (hasUpdate)
              TvFocusable(
                scale: 1.0,
                onTap: () =>
                    context.read<SourcesBloc>().add(SourceUpdated(_key)),
                child: Tooltip(
                  message: 'Update to v$newVersion',
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(
                      Icons.download_rounded,
                      size: 20,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              ),
            // Enable / disable switch — OK flips the toggle.
            TvFocusable(
              scale: 1.0,
              onTap: () => context.read<SourcesBloc>().add(
                SourceEnabledToggled(_key, enabled: !entry.enabled),
              ),
              child: Switch.adaptive(
                value: entry.enabled,
                activeThumbColor: AppColors.accent,
                onChanged: (v) => context.read<SourcesBloc>().add(
                  SourceEnabledToggled(_key, enabled: v),
                ),
              ),
            ),
            // Settings gear — OK pushes SourceSettingsScreen.
            TvFocusable(
              scale: 1.0,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SourceSettingsScreen(
                    sourceId: entry.name,
                    repoUrl: entry.originRepoUrl,
                    displayName: name,
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
            // Remove button — non-bundled sources only, OK shows confirm.
            if (!bundled)
              TvFocusable(
                scale: 1.0,
                onTap: () => _confirmRemove(context),
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Row-level focus halo for [_ZTvInstalledRow]. Wraps the whole row and
/// tints + outlines it whenever any control inside holds focus, so the
/// source you're acting on is obvious alongside the per-control highlight.
class _ZRowFocusHalo extends StatefulWidget {
  const _ZRowFocusHalo({required this.child});
  final Widget child;

  @override
  State<_ZRowFocusHalo> createState() => _ZRowFocusHaloState();
}

class _ZRowFocusHaloState extends State<_ZRowFocusHalo> {
  bool _hasFocus = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (f != _hasFocus) setState(() => _hasFocus = f);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _hasFocus ? AppColors.accent.withValues(alpha: 0.10) : null,
          border: Border.all(
            color: _hasFocus
                ? AppColors.accent.withValues(alpha: 0.55)
                : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: widget.child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim from sources_screen_tv.dart — Repos content.
// ---------------------------------------------------------------------------

class _ZTvReposContent extends StatelessWidget {
  const _ZTvReposContent();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SourcesBloc, SourcesState>(
      buildWhen: (a, b) => a.repos != b.repos || a.installed != b.installed,
      builder: (context, state) {
        final repos = state.repos;
        if (repos.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              message: 'No repos added yet.\nPress "Add repo" to add one.',
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final repo in repos)
              _ZTvRepoGroup(
                repo: repo,
                installedKeys: state.installedKeys,
                updatableKeys: state.updatableKeys,
              ),
          ],
        );
      },
    );
  }
}

class _ZTvRepoGroup extends StatefulWidget {
  const _ZTvRepoGroup({
    required this.repo,
    required this.installedKeys,
    required this.updatableKeys,
  });

  final ProviderRepo repo;
  final Set<String> installedKeys;
  final Set<String> updatableKeys;

  @override
  State<_ZTvRepoGroup> createState() => _ZTvRepoGroupState();
}

class _ZTvRepoGroupState extends State<_ZTvRepoGroup> {
  bool _expanded = true;

  ProviderRepo get repo => widget.repo;

  int get _updateCount => repo.sources
      .where(
        (s) => widget.updatableKeys
            .contains(ProviderRegistry.providerKey(repo.url, s.id)),
      )
      .length;

  Future<void> _removeRepo(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final ok = await _zTvConfirm(
      context,
      title: 'Remove repo?',
      body:
          'Already-installed sources from "${repo.displayName}" stay installed. '
          'You can add the repo back later.',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    bloc.add(RepoRemoved(repo.url, displayName: repo.displayName));
  }

  @override
  Widget build(BuildContext context) {
    final updateCount = _updateCount;
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
                          Text(
                            repo.displayName,
                            style: AppText.headline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            updateCount > 0
                                ? '${repo.sources.length} sources · '
                                      '$updateCount update${updateCount == 1 ? '' : 's'}'
                                : '${repo.sources.length} sources',
                            style: AppText.caption.copyWith(
                              color: updateCount > 0
                                  ? AppColors.accent
                                  : AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // "Refresh" action.
                TvFocusable(
                  scale: 1.0,
                  onTap: () => context
                      .read<SourcesBloc>()
                      .add(RepoRefreshed(repo.url)),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(
                      'Refresh',
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
                // "Update all" action — only when updates exist.
                if (updateCount > 0)
                  TvFocusable(
                    scale: 1.0,
                    onTap: () => context
                        .read<SourcesBloc>()
                        .add(RepoUpdated(repo.url)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(
                        'Update all ($updateCount)',
                        style: AppText.caption.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                // "Remove" action.
                TvFocusable(
                  scale: 1.0,
                  onTap: () => _removeRepo(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    child: Text(
                      'Remove',
                      style:
                          AppText.caption.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── Collapsible source list ─────────────────────────────────────
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
                        // Index-tracked loop so the first row gets autofocus,
                        // routing the D-pad there after the repo is added.
                        for (final (idx, source) in repo.sources
                            .where(
                              (s) =>
                                  !s.nsfw ||
                                  sl<PlaybackPrefs>().nsfwSources,
                            )
                            .indexed) ...[
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                          _ZTvRepoSourceRow(
                            repo: repo,
                            source: source,
                            installed: widget.installedKeys.contains(
                              ProviderRegistry.providerKey(
                                  repo.url, source.id),
                            ),
                            hasUpdate: widget.updatableKeys.contains(
                              ProviderRegistry.providerKey(
                                  repo.url, source.id),
                            ),
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

/// One repo source row. The action button (Install / Update / Uninstall) is
/// a single [TvFocusable] — D-pad OK fires the same bloc event as the phone.
/// [autofocus] should be true only for the first row in a newly expanded list
/// so the remote lands on an actionable Install button without manual nav.
class _ZTvRepoSourceRow extends StatelessWidget {
  const _ZTvRepoSourceRow({
    required this.repo,
    required this.source,
    required this.installed,
    required this.hasUpdate,
    this.autofocus = false,
  });

  final ProviderRepo repo;
  final RepoSource source;
  final bool installed;
  final bool hasUpdate;
  final bool autofocus;

  String get _key => ProviderRegistry.providerKey(repo.url, source.id);

  Future<void> _uninstall(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final ok = await _zTvConfirm(
      context,
      title: 'Uninstall ${source.name}?',
      body: 'The provider will be removed from your installed sources.',
      confirmLabel: 'Uninstall',
    );
    if (!ok) return;
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
                      _ZNsfwBadge(),
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
            TvFocusable(
              scale: 1.0,
              autofocus: autofocus,
              onTap: () =>
                  context.read<SourcesBloc>().add(SourceUpdated(_key)),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.download_rounded,
                        size: 16, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(
                      'Update',
                      style: AppText.caption.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (installed)
            TvFocusable(
              scale: 1.0,
              autofocus: autofocus,
              onTap: () => _uninstall(context),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: AppColors.textSecondary.withValues(alpha: 0.4),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Installed',
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            )
          else
            TvFocusable(
              scale: 1.0,
              autofocus: autofocus,
              onTap: () => context.read<SourcesBloc>().add(
                SourceInstalled(repo: repo, source: source),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
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
Future<bool> _zTvConfirm(
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
// Lifted verbatim from sources_screen_tv.dart — TV Add-repo dialog.
// ---------------------------------------------------------------------------

class _ZTvAddRepoDialog extends StatefulWidget {
  const _ZTvAddRepoDialog({required this.bloc});
  final SourcesBloc bloc;

  @override
  State<_ZTvAddRepoDialog> createState() => _ZTvAddRepoDialogState();
}

class _ZTvAddRepoDialogState extends State<_ZTvAddRepoDialog> {
  final _urlCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  // Explicit FocusNode + postFrameCallback reliably raises the leanback IME on
  // Android TV, where autofocus: true alone often fails inside an AlertDialog.
  final _urlFocus = FocusNode();
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _urlFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _nameCtrl.dispose();
    _urlFocus.dispose();
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
            focusNode: _urlFocus,
            keyboardType: TextInputType.url,
            cursorColor: AppColors.accent,
            style: AppText.body.copyWith(color: AppColors.textPrimary),
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Manifest URL',
              hintText: 'https://.../index.json',
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "Paste the repo's index.json URL.",
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
        TvFocusable(
          scale: 1.0,
          onTap: _loading ? () {} : () => Navigator.of(context).pop(),
          child: TextButton(
            onPressed: _loading ? null : () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ),
        TvFocusable(
          scale: 1.0,
          onTap: _loading ? () {} : _submit,
          child: FilledButton(
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
        ),
      ],
    );
  }
}
