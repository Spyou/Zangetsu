// CloudStream sources — TV (D-pad) UI.
part of 'cloudstream_sources_screen.dart';


// ---------------------------------------------------------------------------
// TV view
// ---------------------------------------------------------------------------

class _CsTvView extends StatefulWidget {
  const _CsTvView();

  @override
  State<_CsTvView> createState() => _CsTvViewState();
}

class _CsTvViewState extends State<_CsTvView> {
  int _tab = 0;
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

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

  @override
  Widget build(BuildContext context) {
    // CloudStream is Android-only (native plugin host) — the old TV screen
    // gated the whole section behind Platform.isAndroid; preserve that here.
    if (!Platform.isAndroid) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Stack(
          children: [
            Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: Text(
                  context.l10n.cloudstreamIsnTAvailableOnThisDevice,
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
                  child: Text(context.l10n.cloudStream, style: AppText.largeTitle),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(40, 0, 40, 16),
                  child: Row(
                    children: [
                      _CsTvTabChip(
                        title: context.l10n.installed,
                        selected: _tab == 0,
                        autofocus: true,
                        onTap: () => setState(() => _tab = 0),
                      ),
                      const SizedBox(width: 12),
                      _CsTvTabChip(
                        title: context.l10n.repositories,
                        selected: _tab == 1,
                        onTap: () => setState(() => _tab = 1),
                      ),
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
                            // ── Installed ────────────────────────────────
                            _CsScreenTvInstalledContent(query: _query),
                          ]
                        : [
                            // ── Repositories ─────────────────────────────
                            _CsScreenTvReposContent(query: _query),
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: TvListFocusable(
                                onTap: _showAddCsRepoDialog,
                                semanticLabel: context.l10n.addCSRepo,
                                child: ExcludeSemantics(
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
                                        Icon(
                                          Icons.add,
                                          color: AppColors.accent,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          context.l10n.addCSRepo,
                                          style: AppText.headline.copyWith(
                                            color: AppColors.accent,
                                          ),
                                        ),
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
class _CsTvTabChip extends StatelessWidget {
  const _CsTvTabChip({
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
      variant: TvFocusVariant.float,
      scale: 1.0,
      borderRadius: 20,
      autofocus: autofocus,
      onTap: onTap,
      semanticLabel: title,
      // Excluded — semanticLabel above already announces the tab name.
      child: ExcludeSemantics(
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
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lifted verbatim (CS-only slice) from sources_screen_tv.dart — Installed.
// Mirrors _TvCsInstalledGroupList / _TvCsInstalledGroup / _TvCsSourceRow.
// ---------------------------------------------------------------------------

class _CsScreenTvInstalledContent extends StatelessWidget {
  const _CsScreenTvInstalledContent({this.query = ''});

  final String query;

  @override
  Widget build(BuildContext context) {
    // Search: keep only matching sources; drop groups left with none.
    final groups = [
      for (final g in sl<CloudStreamManager>().repoGroups)
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
    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: EmptyState(
          icon: Icons.dns_rounded,
          message: query.trim().isEmpty
              ? context.l10n.noCloudStreamSourcesInstalled
              : 'No installed sources match "${query.trim()}".',
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
        widget.group.name.isNotEmpty ? widget.group.name : context.l10n.cloudStream;
    final sources = widget.group.sources;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Group header — OK toggles expand.
        TvListFocusable(
          onTap: () => setState(() => _expanded = !_expanded),
          semanticLabel: '$title, ${sources.length} installed',
          child: ExcludeSemantics(
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
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: !_expanded
              ? const SizedBox(width: double.infinity)
              : Container(
                  clipBehavior: Clip.none,
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
            child: TvListFocusable(
              onTap: () {
                context.read<ActiveSourceCubit>().setSource(source.sourceId);
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    SnackBar(
                      content: Text(context.l10n.activeSourceColon(source.displayName)),
                    ),
                  );
              },
              semanticLabel: active
                  ? '${source.displayName}, active'
                  : '${source.displayName}, set active source',
              child: ExcludeSemantics(
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
                      Text(context.l10n.cloudstream, style: AppText.caption),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Enable/disable toggle — OK flips the state.
          TvListFocusable(
            onTap: () => manager.setEnabled(source.sourceId, !enabled),
            semanticLabel:
                '${source.displayName}, ${enabled ? 'on' : 'off'}',
            // Excluded — the Switch's own "toggled" semantics would
            // otherwise double-announce the on/off state above.
            child: ExcludeSemantics(
              child: Switch.adaptive(
                value: enabled,
                activeThumbColor: AppColors.accent,
                onChanged: (v) => manager.setEnabled(source.sourceId, v),
              ),
            ),
          ),
          // Settings gear.
          TvListFocusable(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SourceSettingsScreen(
                  sourceId: source.sourceId,
                  repoUrl: '',
                  displayName: source.displayName,
                ),
              ),
            ),
            semanticLabel: '${source.displayName}, settings',
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
  const _CsScreenTvReposContent({this.query = ''});

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
    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: EmptyState(
          icon: Icons.cloud_outlined,
          message: searching
              ? context.l10n.noExtensionsMatchQuery(query.trim())
              : context.l10n.noCloudStreamReposAddedYetPress(context.l10n.addCSRepo),
        ),
      );
    }
    return BlocBuilder<ActiveSourceCubit, String>(
      builder: (context, activeId) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in groups)
            _CsScreenTvRepoSection(
              group: group,
              activeId: activeId,
              searching: searching,
            ),
        ],
      ),
    );
  }
}

class _CsScreenTvRepoSection extends StatefulWidget {
  const _CsScreenTvRepoSection({
    required this.group,
    required this.activeId,
    this.searching = false,
  });
  final CsRepoGroup group;
  final String activeId;

  /// True while a search query is active — stays expanded, skips the lazy
  /// catalog fetch (the handed-in catalog may be a filtered subset).
  final bool searching;

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
    if (widget.searching) return;
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
      ..showSnackBar(SnackBar(content: Text(context.l10n.checkingForUpdates)));
    try {
      final updates =
          await sl<CloudStreamManager>().checkRepoUpdates(group.url);
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

  Future<void> _applyUpdates() async {
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

  Future<void> _removeRepo() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _csScreenTvConfirm(
      context,
      title: context.l10n.removeRepository2,
      body: context.l10n.removeThisRepositoryAndItsSources,
      confirmLabel: context.l10n.removeDownloadTooltip,
    );
    if (!ok) return;
    await sl<CloudStreamManager>().deleteRepo(group.url);
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(context.l10n.removed)));
  }

  @override
  Widget build(BuildContext context) {
    final manager = sl<CloudStreamManager>();
    final isOther = group.url.isEmpty;
    final updates = isOther ? const <CsUpdate>[] : manager.updatesFor(group.url);
    final catalog = isOther ? _otherCatalog : group.catalog;
    final title = group.name.isNotEmpty ? group.name : context.l10n.cloudStream;
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
              ? (group.owner.isNotEmpty ? group.owner : context.l10n.cloudstream)
              : '$installedCount of ${catalog.length} installed'
                    '${group.owner.isNotEmpty ? ' • ${group.owner}' : ''}');

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      clipBehavior: Clip.none,
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
                TvListFocusable(
                  onTap: () => setState(() => _expanded = !_expanded),
                  semanticLabel: '$title, $subtitle',
                  child: ExcludeSemantics(
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
                ),
                // Update pill — apply all updates for this repo.
                if (updates.isNotEmpty)
                  TvListFocusable(
                    onTap: _applyUpdates,
                    semanticLabel: '$title, apply ${updates.length == 1 ? context.l10n.oneUpdate : '${updates.length} updates'}',
                    child: ExcludeSemantics(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
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
                  ),
                // context.l10n.checkUpdates — real repos only (no synthetic Other group).
                if (group.url.isNotEmpty)
                  TvListFocusable(
                    onTap: _checkUpdates,
                    semanticLabel: '$title, check updates',
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Text(context.l10n.checkUpdates,
                            style: AppText.caption
                                .copyWith(color: AppColors.textSecondary)),
                      ),
                    ),
                  ),
                // context.l10n.removeRepo2 — real repos only.
                if (group.url.isNotEmpty)
                  TvListFocusable(
                    onTap: _removeRepo,
                    semanticLabel: '$title, remove repo',
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        child: Text(context.l10n.removeDownloadTooltip,
                            style: AppText.caption
                                .copyWith(color: AppColors.textSecondary)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // ── Collapsible plugin catalog (search forces it open) ──────────
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
                          padding:
                              const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            context.l10n.noInstallableSourcesFoundInThisRepo,
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
    final ok = await _csScreenTvConfirm(
      context,
      title: context.l10n.uninstallNameQuestion(widget.plugin.name),
      body: context.l10n.thisRemovesTheSourceFromYourInstalledList,
      confirmLabel: context.l10n.uninstall,
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
            TvActionChip(
              autofocus: widget.autofocus,
              label: 'Update → v${widget.update!.onlineVersion}',
              onTap: _update,
              semanticLabel:
                  '${widget.plugin.name}, update to v${widget.update!.onlineVersion}',
            )
          else if (installed)
            TvActionChip(
              autofocus: widget.autofocus,
              label: context.l10n.installed,
              emphasized: false,
              onTap: _uninstall,
              semanticLabel: '${widget.plugin.name}, uninstall',
            )
          else
            TvActionChip(
              autofocus: widget.autofocus,
              label: context.l10n.install,
              onTap: _install,
              semanticLabel: '${widget.plugin.name}, install',
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
                  TvListFocusable(
                    autofocus: true,
                    onTap: () => Navigator.pop(ctx, false),
                    semanticLabel: context.l10n.cancel,
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        child: Text(
                          context.l10n.cancel,
                          style: AppText.body.copyWith(
                              color: AppColors.textSecondary),
                        ),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        child: Text(
                          confirmLabel,
                          style: AppText.body
                              .copyWith(color: AppColors.accent),
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
  // Not auto-focused on purpose: auto-focusing the field would raise the
  // leanback IME and cover the dialog. D-pad to the field + OK to type a URL.
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
      title: Text(context.l10n.addCSRepo, style: AppText.headline),
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
              decoration: InputDecoration(
                labelText: context.l10n.repoUrl,
                hintText: context.l10n.repoUrlHint,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.pasteACloudStreamRepositoryURL,
              style: AppText.caption,
            ),
          ],
        ),
      ),
      actions: [
        TvListFocusable(
          onTap: () => Navigator.of(context).pop(),
          semanticLabel: context.l10n.cancel,
          child: ExcludeSemantics(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                context.l10n.cancel,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ),
        ),
        TvListFocusable(
          onTap: _submit,
          semanticLabel: context.l10n.navTabsAdd,
          child: ExcludeSemantics(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: _submit,
              child: Text(context.l10n.navTabsAdd),
            ),
          ),
        ),
      ],
    );
  }
}
