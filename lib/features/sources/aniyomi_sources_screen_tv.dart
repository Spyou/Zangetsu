// Aniyomi sources — TV (D-pad) UI.
part of 'aniyomi_sources_screen.dart';


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
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Aniyomi is Android-only (native extension host) — the old TV screen
    // gated this whole section behind Platform.isAndroid; preserve that here.
    if (!Platform.isAndroid) {
      return Scaffold(
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
                      const SizedBox(width: 12),
                      TvFocusable(
                        scale: 1.04,
                        onTap: () => showSourceLanguageSheetTv(
                          context,
                          sl<AnimeLangPrefs>(),
                        ),
                        semanticLabel: 'Languages',
                        child: ExcludeSemantics(
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(
                              Icons.language_rounded,
                              color: AppColors.accent,
                              size: 20,
                            ),
                          ),
                        ),
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
                            _AniScreenTvInstalledContent(query: _query),
                          ]
                        : [
                            // ── Repositories ─────────────────────────────
                            _AniScreenTvContent(
                              repoUrls: widget.repoUrls,
                              onRemoveRepo: widget.onRemoveRepo,
                              query: _query,
                            ),
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: TvFocusable(
                                scale: 1.0,
                                onTap: widget.onAddRepo,
                                semanticLabel: 'Add Aniyomi repo',
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
  const _AniScreenTvInstalledContent({this.query = ''});

  final String query;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<AniyomiManager>(),
      builder: (context, _) {
        final sources = sl<AniyomiManager>()
            .all
            .where((p) => sourceSearchMatches(
                query,
                p.displayName,
                p is AniyomiProvider ? p.info.lang : null))
            .toList();
        if (sources.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.extension_outlined,
              message: query.trim().isEmpty
                  ? 'No Aniyomi sources installed.'
                  : 'No installed sources match "${query.trim()}".',
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
        semanticLabel: active
            ? '${source.displayName}, active'
            : '${source.displayName}, set active source',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              // Excluded — semanticLabel above already announces the name;
              // the settings gear below is its own separate focusable and
              // keeps its own semantics.
              Expanded(
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        source.displayName,
                        style: AppText.headline.copyWith(
                          color: active
                              ? AppColors.accent
                              : AppColors.textPrimary,
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
              ),
              if (_hasSettings)
                TvFocusable(
                  scale: 1.0,
                  onTap: _openSettings,
                  semanticLabel: '${source.displayName}, settings',
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
    this.query = '',
  });

  final List<String> repoUrls;
  final void Function(String url) onRemoveRepo;

  /// Live search query — each repo section filters its entries by it.
  final String query;

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
            query: query,
          ),
      ],
    );
  }
}

class _AniScreenTvRepoSection extends StatefulWidget {
  const _AniScreenTvRepoSection({
    required this.url,
    required this.onRemove,
    this.query = '',
  });

  final String url;
  final VoidCallback onRemove;

  /// Live search query — filters the fetched entries; a non-empty query also
  /// forces the section open and hides it entirely when nothing matches.
  final String query;

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

  final AnimeLangPrefs? _langPrefs =
      sl.isRegistered<AnimeLangPrefs>() ? sl<AnimeLangPrefs>() : null;

  @override
  void initState() {
    super.initState();
    _langPrefs?.addListener(_onLangsChanged);
    _loadInstalled();
    _fetch();
  }

  @override
  void dispose() {
    _langPrefs?.removeListener(_onLangsChanged);
    super.dispose();
  }

  void _onLangsChanged() {
    if (mounted) setState(() {});
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
    final searching = widget.query.trim().isNotEmpty;
    final enabled = _langPrefs == null
        ? null
        : (_langPrefs.enabled ?? defaultSourceLangs());
    final entries = [
      for (final e in _entries ?? const <AniyomiRepoEntry>[])
        if (sourceSearchMatches(widget.query, e.name, e.lang) &&
            (enabled == null || sourceLangVisible(e.lang, enabled)))
          e,
    ];
    // While searching, a fully-loaded section with zero matches disappears.
    if (searching && !_fetching && _fetchError == null && entries.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusable(
            scale: 1.0,
            onTap: () => setState(() => _expanded = !_expanded),
            semanticLabel: '$_repoDisplayName, '
                '${_fetching ? 'loading' : _fetchError != null ? 'error' : '${entries.length} extensions'}',
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
                  // Excluded — semanticLabel above already announces the
                  // repo name and status.
                  Expanded(
                    child: ExcludeSemantics(
                      child: Text(
                        _repoDisplayName,
                        style: AppText.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  ExcludeSemantics(
                    child: Text(
                      _fetching
                          ? 'Loading…'
                          : _fetchError != null
                          ? 'Error'
                          : '${entries.length} ext.',
                      style: AppText.caption,
                    ),
                  ),
                  const SizedBox(width: 12),
                  TvFocusable(
                    scale: 1.0,
                    onTap: widget.onRemove,
                    semanticLabel: '$_repoDisplayName, remove repo',
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
          if ((_expanded || searching) && !_fetching && entries.isNotEmpty)
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
        semanticLabel: '${entry.name}, ${installed ? 'uninstall' : 'install'}',
        child: ExcludeSemantics(
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
                  SizedBox(
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
                      color: installed
                          ? AppColors.textSecondary
                          : AppColors.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
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
                    semanticLabel: 'Cancel',
                    child: ExcludeSemantics(
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
                  ),
                  const SizedBox(width: 4),
                  // Confirm action.
                  TvFocusable(
                    scale: 1.0,
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
          ],
        ),
      ),
      actions: [
        TvFocusable(
          scale: 1.0,
          onTap: () => Navigator.of(context).pop(),
          semanticLabel: 'Cancel',
          child: ExcludeSemantics(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                'Cancel',
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ),
        ),
        TvFocusable(
          scale: 1.0,
          onTap: _submit,
          semanticLabel: 'Add',
          child: ExcludeSemantics(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: _submit,
              child: const Text('Add'),
            ),
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
