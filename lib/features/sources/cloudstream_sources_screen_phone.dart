// CloudStream sources — phone UI.
part of 'cloudstream_sources_screen.dart';


// ---------------------------------------------------------------------------
// Phone view
// ---------------------------------------------------------------------------

class _CsPhoneView extends StatefulWidget {
  const _CsPhoneView();

  @override
  State<_CsPhoneView> createState() => _CsPhoneViewState();
}

class _CsPhoneViewState extends State<_CsPhoneView> {
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
          title: Text(context.l10n.cloudStream, style: AppText.barTitle),
          bottom: TabBar(
            indicatorColor: AppColors.accent,
            indicatorSize: TabBarIndicatorSize.label,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textSecondary,
            labelStyle: AppText.headline,
            unselectedLabelStyle: AppText.headline,
            dividerHeight: 0,
            tabs: [
              Tab(text: context.l10n.installed),
              Tab(text: context.l10n.repositories),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          onPressed: () => _showAddCsRepoDialog(context),
          icon: const Icon(Icons.add),
          label: Text(
            context.l10n.addCloudStreamRepo,
            style: AppText.button.copyWith(color: Colors.white),
          ),
        ),
        // NOT const: a const TabBarView is canonicalized, so the outer
        // ListenableBuilder's rebuild would hand Flutter the identical subtree
        // and skip it — the install/enable state would never refresh. A fresh
        // instance lets the manager's notifyListeners() reach the tabs.
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
                  _CsInstalledTab(query: _query),
                  _CsReposTab(query: _query),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Installed tab body — CS sources grouped by origin repo.
class _CsInstalledTab extends StatelessWidget {
  const _CsInstalledTab({this.query = ''});

  final String query;

  @override
  Widget build(BuildContext context) {
    final groups = sl<CloudStreamManager>().repoGroups;
    // Search: keep only matching sources; drop groups left with none.
    final installedGroups = [
      for (final g in groups)
        if (g.sources.any((s) => sourceSearchMatches(query, s.displayName)))
          CsRepoGroup(
            url: g.url,
            name: g.name,
            owner: g.owner,
            catalog: g.catalog,
            sources: [
              for (final s in g.sources)
                if (sourceSearchMatches(query, s.displayName)) s,
            ],
          ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        if (installedGroups.isEmpty)
          EmptyState(
            icon: Icons.dns_rounded,
            message: query.trim().isEmpty
                ? context.l10n.noCloudStreamSourcesInstalled
                : 'No installed sources match "${query.trim()}".',
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
      ],
    );
  }
}

/// Repositories tab body — add repo action + repo browse/install sections.
class _CsReposTab extends StatelessWidget {
  const _CsReposTab({this.query = ''});

  final String query;

  @override
  Widget build(BuildContext context) {
    final searching = query.trim().isNotEmpty;
    final all = sl<CloudStreamManager>().repoGroups;
    // Search: keep only matching catalog plugins; drop repos left with none.
    final groups = !searching
        ? all
        : [
            for (final g in all)
              if (g.catalog
                  .any((m) => sourceSearchMatches(query, m.name, m.language)))
                CsRepoGroup(
                  url: g.url,
                  name: g.name,
                  owner: g.owner,
                  catalog: [
                    for (final m in g.catalog)
                      if (sourceSearchMatches(query, m.name, m.language)) m,
                  ],
                  sources: g.sources,
                ),
          ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        if (groups.isEmpty)
          EmptyState(
            icon: Icons.cloud_outlined,
            message: searching
                ? context.l10n.noExtensionsMatchQuery(query.trim())
                : context.l10n.noCloudStreamReposAddedYetTap(context.l10n.addCSRepo),
          )
        else
          BlocBuilder<ActiveSourceCubit, String>(
            builder: (context, activeId) => Column(
              children: [
                for (final group in groups)
                  _CsScreenRepoSection(
                    group: group,
                    activeId: activeId,
                    searching: searching,
                  ),
              ],
            ),
          ),
      ],
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
                ? context.l10n.repoAdded
                : context.l10n.repoAddedWithSourcesAvailable(count),
          ),
        ),
      );
  } catch (e) {
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(context.l10n.failedToAddRepo('$e'))));
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
        : context.l10n.cloudStream;
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
/// disabled) and a `context.l10n.cloudstream` meta line, then a [Switch.adaptive] for
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
            SnackBar(content: Text(context.l10n.activeSourceColon(source.displayName))),
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
                  Text(context.l10n.cloudstream, style: AppText.caption),
                ],
              ),
            ),
            Switch.adaptive(
              value: enabled,
              activeThumbColor: AppColors.accent,
              onChanged: (v) => manager.setEnabled(source.sourceId, v),
            ),
            IconButton(
              tooltip: context.l10n.sourceSettings,
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
/// [CloudStreamManager.deleteRepo]; shows a context.l10n.removed snackbar on success.
Future<void> _confirmDeleteCsRepo(BuildContext context, CsRepoGroup group) async {
  final messenger = ScaffoldMessenger.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(context.l10n.removeRepository2, style: AppText.headline),
      content: Text(
        context.l10n.removeThisRepositoryAndItsSources,
        style: AppText.body,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(
            context.l10n.cancel,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
            context.l10n.removeDownloadTooltip,
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
    ..showSnackBar(SnackBar(content: Text(context.l10n.removed)));
}

/// READ-ONLY check of a CloudStream repo for plugin updates via
/// [CloudStreamManager.checkRepoUpdates] (no download). Reports how many
/// updates are available; the accent badge + per-plugin context.l10n.update buttons then
/// appear.
Future<void> _checkCsUpdates(BuildContext context, CsRepoGroup group) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(context.l10n.checkingForUpdates)));
  try {
    final updates = await sl<CloudStreamManager>().checkRepoUpdates(group.url);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            updates.isEmpty
                ? context.l10n.upToDate
                : context.l10n.nUpdatesAvailable(updates.length),
          ),
        ),
      );
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.l10n.checkFailed('$e'))));
  }
}

/// Applies all available updates for a repo (re-download newer `.cs3`s) via
/// [CloudStreamManager.updateRepo], with progress + an honest result count.
Future<void> _applyCsRepoUpdates(BuildContext context, CsRepoGroup group) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(context.l10n.updating)));
  try {
    final count = await sl<CloudStreamManager>().updateRepo(group.url);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            count == 0 ? context.l10n.alreadyUpToDate : context.l10n.updatedNSources(count),
          ),
        ),
      );
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(context.l10n.updateFailed('$e'))));
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
  const _CsScreenRepoSection({
    required this.group,
    required this.activeId,
    this.searching = false,
  });

  final CsRepoGroup group;
  final String activeId;

  /// True while a search query is active: the section stays expanded so the
  /// matches are visible, and the lazy catalog fetch is skipped (the filtered
  /// catalog handed in may be a subset of the real one).
  final bool searching;

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
    if (widget.searching) return;
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
    final title = group.name.isNotEmpty ? group.name : context.l10n.cloudStream;
    final owner = group.owner.isNotEmpty
        ? group.owner
        : (group.url.isNotEmpty ? group.url : null);
    final subtitle = isOther
        ? '${group.sources.length} installed'
        : (catalog.isEmpty
              ? (owner ?? context.l10n.cloudstream)
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
                            ? context.l10n.oneUpdate
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
                          context.l10n.checkForUpdates,
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
                          context.l10n.removeRepo2,
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
          // Collapsible catalog list (install one by one). A live search
          // forces the section open so its matches are visible.
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !(_expanded || widget.searching)
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (catalog.isEmpty && _fetching)
                        Padding(
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
                            context.l10n.noInstallableSourcesFoundInThisRepo,
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
  /// set, the row shows an context.l10n.update button instead of context.l10n.installed.
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
    return parts.isEmpty ? context.l10n.cloudstream : parts.join(' • ');
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
          SnackBar(content: Text(context.l10n.installedName(widget.plugin.name))),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(context.l10n.installFailed('$e'))));
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
          SnackBar(content: Text(context.l10n.updatedName(widget.plugin.name))),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(context.l10n.updateFailed('$e'))));
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
        title: Text(context.l10n.uninstallNameQuestion(widget.plugin.name), style: AppText.headline),
        content: Text(
          context.l10n.thisRemovesTheSourceFromYourInstalledList,
          style: AppText.body,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              context.l10n.cancel,
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              context.l10n.uninstall,
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
          SnackBar(content: Text(context.l10n.uninstalledName(widget.plugin.name))),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(context.l10n.uninstallFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Read live from the manager (not the parent-computed widget.installed) so
    // this row's own setState after _install/_uninstall reflects the new state
    // immediately, even if the parent group hasn't rebuilt.
    final installed = sl<CloudStreamManager>()
        .isPluginInstalled(widget.plugin.internalName, repoUrl: widget.repoUrl);
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
            SizedBox(
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
              child: Text(context.l10n.updateArrowVersion('${widget.update!.onlineVersion}')),
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
              child: Text(context.l10n.installed),
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
              child: Text(context.l10n.install),
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(context.l10n.addCSRepo, style: AppText.headline),
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
              decoration: InputDecoration(
                labelText: context.l10n.repoUrl,
                hintText: context.l10n.repoUrlHint,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.pasteCloudStreamRepoUrlFull,
              style: AppText.caption,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            context.l10n.cancel,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
          ),
          onPressed: _submit,
          child: Text(context.l10n.navTabsAdd),
        ),
      ],
    );
  }
}
