// Zangetsu sources — TV (D-pad) UI.
part of 'zangetsu_sources_screen.dart';

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
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

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
      listenWhen: (a, b) => b.notice != null && (a.notice != b.notice || a.noticeSeq != b.noticeSeq),
      listener: (context, state) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(state.notice!)));
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
                    child: Text(context.l10n.zangetsuProviders, style: AppText.largeTitle),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(40, 0, 40, 16),
                    child: Row(
                      children: [
                        _ZTvTabChip(
                          title: context.l10n.installed,
                          selected: _tab == 0,
                          autofocus: true,
                          onTap: () => setState(() => _tab = 0),
                        ),
                        const SizedBox(width: 12),
                        _ZTvTabChip(title: context.l10n.repositories, selected: _tab == 1, onTap: () => setState(() => _tab = 1)),
                        const SizedBox(width: 20),
                        Expanded(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 340),
                            child: SourcesSearchField(
                              controller: _searchCtrl,
                              onChanged: (q) => setState(() => _query = q),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      clipBehavior: Clip.none,
                      padding: const EdgeInsets.fromLTRB(40, 0, 40, 48),
                      children: _tab == 0
                          ? [
                              // ── Installed ────────────────────────────
                              _ZTvInstalledContent(query: _query),
                            ]
                          : [
                              // ── Repositories ──────────────────────────
                              _ZTvReposContent(query: _query),
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: TvListFocusable(
                                  onTap: _showAddRepoDialog,
                                  semanticLabel: context.l10n.addRepo,
                                  child: ExcludeSemantics(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                                      decoration: BoxDecoration(
                                        color: AppColors.surface,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.add, color: AppColors.accent, size: 18),
                                          const SizedBox(width: 8),
                                          Text(context.l10n.addRepo, style: AppText.headline.copyWith(color: AppColors.accent)),
                                        ],
                                      ),
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
            const Positioned(top: 8, left: 8, child: SafeArea(child: TvBackButton())),
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
  const _ZTvTabChip({required this.title, required this.selected, required this.onTap, this.autofocus = false});

  final String title;
  final bool selected;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      // Poster-style white outline; no scale so ListView/row clip won't shave it.
      variant: TvFocusVariant.float,
      scale: 1.0,
      // Match the stadium chip (r=20) so the ring hugs the pill ends.
      borderRadius: 20,
      autofocus: autofocus,
      onTap: onTap,
      semanticLabel: title,
      // Excluded — semanticLabel above already announces the tab name.
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.accent.withValues(alpha: 0.18) : AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? AppColors.accent : Colors.transparent, width: 2),
          ),
          child: Text(
            title,
            style: AppText.headline.copyWith(color: selected ? AppColors.accent : AppColors.textSecondary),
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
  const _ZTvInstalledContent({this.query = ''});

  final String query;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SourcesBloc, SourcesState>(
      buildWhen: (a, b) => a.installed != b.installed || a.repos != b.repos,
      builder: (context, state) {
        final entries = state.installed
            .where((e) => sourceSearchMatches(query, e.displayName.isNotEmpty ? e.displayName : e.name))
            .toList();
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.dns_rounded,
              message: query.trim().isEmpty
                  ? context.l10n.noProvidersInstalled
                  : context.l10n.noInstalledProvidersMatchQuery(query.trim()),
            ),
          );
        }

        // Group JS providers by origin repo (same logic as phone).
        final groups = <String, List<ProviderRegistryEntry>>{};
        for (final e in entries) {
          final key = e.originRepoUrl.isEmpty ? kBundledRepoUrl : e.originRepoUrl;
          groups.putIfAbsent(key, () => []).add(e);
        }
        final repoByUrl = {for (final r in state.repos) r.url: r};

        String nameFor(String repoUrl) {
          if (repoUrl == kBundledRepoUrl) return context.l10n.builtIn;
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
                searching: query.trim().isNotEmpty,
                entries: groups[key]!
                  ..sort((a, b) {
                    final an = a.displayName.isNotEmpty ? a.displayName : a.name;
                    final bn = b.displayName.isNotEmpty ? b.displayName : b.name;
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
  const _ZTvInstalledGroup({required this.title, required this.entries, required this.state, this.searching = false});

  final String title;
  final List<ProviderRegistryEntry> entries;
  final SourcesState state;

  /// True while a search query is active — the group stays expanded so its
  /// matches are visible.
  final bool searching;

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
        TvListFocusable(
          onTap: () => setState(() => _expanded = !_expanded),
          semanticLabel: '${widget.title}, ${entries.length} installed',
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
              child: Row(
                children: [
                  AnimatedRotation(
                    turns: _expanded ? 0 : -0.25,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more, color: AppColors.textTertiary, size: 20),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.title.toUpperCase(),
                      style: AppText.overline.copyWith(color: AppColors.textTertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text('${entries.length}', style: AppText.overline.copyWith(color: AppColors.textTertiary)),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          // A live search forces the group open so matches are visible.
          child: !(_expanded || widget.searching)
              ? const SizedBox(width: double.infinity)
              : Container(
                  clipBehavior: Clip.none,
                  decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
                  child: Column(
                    children: [
                      for (var i = 0; i < entries.length; i++) ...[
                        if (i > 0) const Divider(height: 0.5, thickness: 0.5, color: AppColors.hairline),
                        _ZTvInstalledRow(entry: entries[i], state: widget.state),
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
  const _ZTvInstalledRow({required this.entry, required this.state});

  final ProviderRegistryEntry entry;
  final SourcesState state;

  String get _key => ProviderRegistry.providerKey(entry.originRepoUrl, entry.name);

  Future<void> _confirmRemove(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final name = entry.displayName.isNotEmpty ? entry.displayName : entry.name;
    final ok = await _zTvConfirm(
      context,
      title: context.l10n.removeNameQuestion(name),
      body: context.l10n.theProviderWillBeRemovedFromYourInstalledSources,
      confirmLabel: context.l10n.removeDownloadTooltip,
    );
    if (!ok) return;
    bloc.add(SourceUninstalled(_key, displayName: name));
  }

  @override
  Widget build(BuildContext context) {
    final bundled = entry.isBundled;
    final name = entry.displayName.isNotEmpty ? entry.displayName : entry.name;
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
                  Text(meta, style: AppText.caption.copyWith(color: hasUpdate ? AppColors.accent : null)),
                ],
              ),
            ),
            // Update button — present only when a newer version is available.
            if (hasUpdate)
              TvListFocusable(
                onTap: () => context.read<SourcesBloc>().add(SourceUpdated(_key)),
                semanticLabel: '$name, update to v$newVersion',
                child: Tooltip(
                  message: 'Update to v$newVersion',
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.download_rounded, size: 20, color: AppColors.accent),
                  ),
                ),
              ),
            // Enable / disable switch — OK flips the toggle.
            TvListFocusable(
              onTap: () => context.read<SourcesBloc>().add(SourceEnabledToggled(_key, enabled: !entry.enabled)),
              variant: TvFocusVariant.none,
              semanticLabel: '$name, ${entry.enabled ? 'on' : 'off'}',
              // Excluded — the Switch's own "toggled" semantics would
              // otherwise double-announce the on/off state above.
              child: ExcludeSemantics(
                child: Switch.adaptive(
                  value: entry.enabled,
                  activeThumbColor: AppColors.accent,
                  onChanged: (v) => context.read<SourcesBloc>().add(SourceEnabledToggled(_key, enabled: v)),
                ),
              ),
            ),
            // Settings gear — OK pushes SourceSettingsScreen.
            TvListFocusable(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      SourceSettingsScreen(sourceId: entry.name, repoUrl: entry.originRepoUrl, displayName: name),
                ),
              ),
              semanticLabel: '$name, settings',
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(Icons.tune_rounded, size: 20, color: AppColors.textSecondary),
              ),
            ),
            // Remove button — non-bundled sources only, OK shows confirm.
            if (!bundled)
              TvListFocusable(
                onTap: () => _confirmRemove(context),
                semanticLabel: '$name, remove',
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.delete_outline_rounded, size: 20, color: AppColors.textSecondary),
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (_hasFocus)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.10),
                      border: Border.all(color: AppColors.accent.withValues(alpha: 0.55), width: 2),
                      borderRadius: BorderRadius.circular(10),
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
// Lifted verbatim from sources_screen_tv.dart — Repos content.
// ---------------------------------------------------------------------------

class _ZTvReposContent extends StatelessWidget {
  const _ZTvReposContent({this.query = ''});

  final String query;

  @override
  Widget build(BuildContext context) {
    final searching = query.trim().isNotEmpty;
    return BlocBuilder<SourcesBloc, SourcesState>(
      buildWhen: (a, b) => a.repos != b.repos || a.installed != b.installed,
      builder: (context, state) {
        // Search: keep only repos with at least one matching source.
        final repos = !searching
            ? state.repos
            : [
                for (final r in state.repos)
                  if (r.sources.any((s) => sourceSearchMatches(query, s.name, s.lang))) r,
              ];
        if (repos.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              message: searching
                  ? context.l10n.noProvidersMatchQuery(query.trim())
                  : context.l10n.noReposAddedYetPress(context.l10n.addRepo),
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
                query: query,
              ),
          ],
        );
      },
    );
  }
}

class _ZTvRepoGroup extends StatefulWidget {
  const _ZTvRepoGroup({required this.repo, required this.installedKeys, required this.updatableKeys, this.query = ''});

  final ProviderRepo repo;
  final Set<String> installedKeys;
  final Set<String> updatableKeys;

  /// Live search query — filters the source rows; a non-empty query also
  /// forces the group open so matches are visible.
  final String query;

  @override
  State<_ZTvRepoGroup> createState() => _ZTvRepoGroupState();
}

class _ZTvRepoGroupState extends State<_ZTvRepoGroup> {
  bool _expanded = true;

  ProviderRepo get repo => widget.repo;

  int get _updateCount =>
      repo.sources.where((s) => widget.updatableKeys.contains(ProviderRegistry.providerKey(repo.url, s.id))).length;

  Future<void> _removeRepo(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final ok = await _zTvConfirm(
      context,
      title: context.l10n.removeRepo,
      body:
          context.l10n.alreadyInstalledSourcesFromRepoStay(repo.displayName) +
          context.l10n.youCanAddRepoBackLater,
      confirmLabel: context.l10n.removeDownloadTooltip,
    );
    if (!ok) return;
    bloc.add(RepoRemoved(repo.url, displayName: repo.displayName));
  }

  @override
  Widget build(BuildContext context) {
    final updateCount = _updateCount;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.none,
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(14)),
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
                TvListFocusable(
                  onTap: () => setState(() => _expanded = !_expanded),
                  semanticLabel: '${repo.displayName}, ${repo.sources.length} sources',
                  child: ExcludeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedRotation(
                          turns: _expanded ? 0 : -0.25,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(Icons.expand_more, color: AppColors.textSecondary, size: 22),
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
                                color: updateCount > 0 ? AppColors.accent : AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                // context.l10n.refresh action.
                TvListFocusable(
                  onTap: () => context.read<SourcesBloc>().add(RepoRefreshed(repo.url)),
                  semanticLabel: '${repo.displayName}, refresh',
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text(context.l10n.refresh, style: AppText.caption.copyWith(color: AppColors.textSecondary)),
                    ),
                  ),
                ),
                // "Update all" action — only when updates exist.
                if (updateCount > 0)
                  TvListFocusable(
                    onTap: () => context.read<SourcesBloc>().add(RepoUpdated(repo.url)),
                    semanticLabel: '${repo.displayName}, update all ($updateCount)',
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        child: Text(
                          context.l10n.updateAllCount(updateCount),
                          style: AppText.caption.copyWith(color: AppColors.accent, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                // context.l10n.removeDownloadTooltip action.
                TvListFocusable(
                  onTap: () => _removeRepo(context),
                  semanticLabel: '${repo.displayName}, remove',
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text(context.l10n.removeDownloadTooltip, style: AppText.caption.copyWith(color: AppColors.textSecondary)),
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
            // A live search forces the group open so matches are visible.
            child: !(_expanded || widget.query.trim().isNotEmpty)
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (repo.sources.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            context.l10n.noSourcesInThisRepoYet,
                            textAlign: TextAlign.center,
                            style: AppText.caption,
                          ),
                        )
                      else
                        // Index-tracked loop so the first row gets autofocus,
                        // routing the D-pad there after the repo is added.
                        // A live search also filters by name/lang.
                        for (final (idx, source)
                            in repo.sources
                                .where(
                                  (s) =>
                                      (!s.nsfw || sl<PlaybackPrefs>().nsfwSources) &&
                                      sourceSearchMatches(widget.query, s.name, s.lang),
                                )
                                .indexed) ...[
                          const Divider(height: 0.5, thickness: 0.5, color: AppColors.hairline),
                          _ZTvRepoSourceRow(
                            repo: repo,
                            source: source,
                            installed: widget.installedKeys.contains(ProviderRegistry.providerKey(repo.url, source.id)),
                            hasUpdate: widget.updatableKeys.contains(ProviderRegistry.providerKey(repo.url, source.id)),
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
      title: context.l10n.uninstallNameQuestion(source.name),
      body: context.l10n.theProviderWillBeRemovedFromYourInstalledSources,
      confirmLabel: context.l10n.uninstall,
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
                    if (source.nsfw) ...[const SizedBox(width: 8), _ZNsfwBadge()],
                  ],
                ),
                const SizedBox(height: 2),
                Text('${source.lang} • v${source.version}', style: AppText.caption),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (installed && hasUpdate)
            TvActionChip(
              autofocus: autofocus,
              label: context.l10n.update,
              icon: Icons.download_rounded,
              onTap: () => context.read<SourcesBloc>().add(SourceUpdated(_key)),
              semanticLabel: '${source.name}, update',
            )
          else if (installed)
            TvActionChip(
              autofocus: autofocus,
              label: context.l10n.installed,
              emphasized: false,
              onTap: () => _uninstall(context),
              semanticLabel: '${source.name}, uninstall',
            )
          else
            TvActionChip(
              autofocus: autofocus,
              label: context.l10n.install,
              onTap: () => context.read<SourcesBloc>().add(SourceInstalled(repo: repo, source: source)),
              semanticLabel: '${source.name}, install',
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
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
              child: Text(body, style: AppText.body.copyWith(color: AppColors.textSecondary)),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Cancel — autofocused so D-pad lands here first.
                  TvListFocusable(
                    autofocus: true,
                    onTap: () => Navigator.pop(ctx, false),
                    semanticLabel: context.l10n.cancel,
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        child: Text(context.l10n.cancel, style: AppText.body.copyWith(color: AppColors.textSecondary)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // Confirm action.
                  TvListFocusable(
                    onTap: () => Navigator.pop(ctx, true),
                    semanticLabel: confirmLabel,
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        child: Text(confirmLabel, style: AppText.body.copyWith(color: AppColors.accent)),
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
    final error = await widget.bloc.addRepo(url, customName: name.isEmpty ? null : name);
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
      title: Text(context.l10n.addRepo, style: AppText.headline),
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
            decoration: InputDecoration(
                labelText: context.l10n.customNameOptional,
              hintText: context.l10n.leaveBlankToUseTheRepoSOwnName,
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
            decoration: InputDecoration(labelText: context.l10n.manifestUrl, hintText: context.l10n.manifestUrlHint),
              ),
          const SizedBox(height: 10),
          Text(context.l10n.pasteRepoIndexJsonUrlShort, style: AppText.caption),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: AppText.caption.copyWith(color: AppColors.accent)),
          ],
        ],
      ),
      actions: [
        TvListFocusable(
          onTap: _loading ? () {} : () => Navigator.of(context).pop(),
          semanticLabel: context.l10n.cancel,
          child: ExcludeSemantics(
            child: TextButton(
              onPressed: _loading ? null : () => Navigator.of(context).pop(),
              child: Text(context.l10n.cancel, style: AppText.body.copyWith(color: AppColors.textSecondary)),
            ),
          ),
        ),
        TvListFocusable(
          onTap: _loading ? () {} : _submit,
          semanticLabel: context.l10n.navTabsAdd,
          child: ExcludeSemantics(
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.accent, foregroundColor: Colors.white),
              onPressed: _loading ? null : _submit,
              child: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(context.l10n.navTabsAdd),
            ),
          ),
        ),
      ],
    );
  }
}
