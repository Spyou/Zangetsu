import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';

import '../../core/aniyomi/aniyomi_repo.dart';
import '../../core/di/injector.dart';
import '../../core/i18n/source_languages.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/mihon/mihon_manager.dart';
import '../../core/mihon/mihon_repo.dart';
import '../../core/mihon/mihon_update.dart';
import '../../core/prefs/source_lang_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import 'sources_search_field.dart';

/// Hive box name for persisted Mihon repo URLs.
///
/// Deliberately separate from `kAniyomiReposBoxName` ('aniyomi_repos') so the
/// two repo lists (and the extensions installed from them) never collide.
const String kMihonReposBoxName = 'mihon_repos';

// ---------------------------------------------------------------------------
// Public add-repo dialog (structural twin of AniyomiAddRepoDialog)
// ---------------------------------------------------------------------------

/// Dialog for adding a Mihon manga extension repository.
///
/// Returns the chosen repo URL (base URL without `/index.json`) via
/// [Navigator.pop(context, url)] when the user picks a recommendation or
/// submits the URL field.  Returns null on cancel.
///
/// [alreadyAddedUrls] marks repos that have already been added so they show
/// an "Added" label instead of an "Add" button.
///
/// Structural twin of `AniyomiAddRepoDialog`
/// (`lib/features/sources/aniyomi_repo_tab.dart`) — deliberately duplicated
/// rather than shared (spec Decision 3).
class MihonAddRepoDialog extends StatefulWidget {
  const MihonAddRepoDialog({super.key, this.alreadyAddedUrls = const {}});

  final Set<String> alreadyAddedUrls;

  @override
  State<MihonAddRepoDialog> createState() => _MihonAddRepoDialogState();
}

class _MihonAddRepoDialogState extends State<MihonAddRepoDialog> {
  final _urlCtrl = TextEditingController();

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final url = _urlCtrl.text.trim();
    if (url.isNotEmpty) Navigator.pop(context, url);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text('Add Mihon repo', style: AppText.headline),
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
                labelText: 'Repo base URL',
                hintText: 'https://.../repo',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              "Paste the repo's base URL — the app appends "
              '"/index.json" automatically.',
              style: AppText.caption,
            ),
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
// Public repo tab — injectable seams for tests
// ---------------------------------------------------------------------------

/// The content of the Mihon tab: one collapsible card per tracked repo, each
/// listing its manga extensions with Install / Installed actions.
///
/// [repoUrls] is the list of tracked repo base URLs (owned by the caller —
/// the Mihon sources screen, not yet built as of this widget).
/// [onRemoveRepo] removes a URL from that list.
///
/// All four optional callbacks are injectable seams for widget tests so the
/// network, native channel, and Hive are never touched:
/// - [fetchIndexFn]: replaces [MihonRepo.fetchIndex] (the manga index reader —
///   the anime `AniyomiRepo.fetchIndex` reads a different file in a different
///   shape and returns two deprecation stubs for keiyoushi).
/// - [installFn]: replaces [MihonExtensionService.installFromRepo].
/// - [uninstallFn]: replaces the default uninstall logic.
/// - [installedPkgsFn]: replaces the Hive-box installed check.
///
/// Structural twin of `AniyomiRepoTab`
/// (`lib/features/sources/aniyomi_repo_tab.dart`) — deliberately duplicated
/// rather than shared (spec Decision 3).
class MihonRepoTab extends StatelessWidget {
  const MihonRepoTab({
    super.key,
    required this.repoUrls,
    required this.onRemoveRepo,
    this.query = '',
    this.fetchIndexFn,
    this.installFn,
    this.uninstallFn,
    this.installedPkgsFn,
  });

  final List<String> repoUrls;
  final void Function(String url) onRemoveRepo;

  /// Live search query — each repo section filters its entries by it.
  final String query;

  final Future<List<AniyomiRepoEntry>> Function(String url)? fetchIndexFn;
  final Future<void> Function(AniyomiRepoEntry entry)? installFn;
  final Future<void> Function(String pkg)? uninstallFn;
  final bool Function(String pkg)? installedPkgsFn;

  @override
  Widget build(BuildContext context) {
    if (repoUrls.isEmpty) {
      return const EmptyState(
        icon: Icons.extension_outlined,
        message: 'No Mihon repos added yet.\nTap "Add Mihon repo" to add one.',
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () async {},
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: repoUrls.length,
        itemBuilder: (_, i) => _MihonRepoSection(
          url: repoUrls[i],
          onRemove: () => onRemoveRepo(repoUrls[i]),
          query: query,
          fetchIndexFn: fetchIndexFn,
          installFn: installFn,
          uninstallFn: uninstallFn,
          installedPkgsFn: installedPkgsFn,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Collapsible repo card
// ---------------------------------------------------------------------------

class _MihonRepoSection extends StatefulWidget {
  const _MihonRepoSection({
    required this.url,
    required this.onRemove,
    this.query = '',
    this.fetchIndexFn,
    this.installFn,
    this.uninstallFn,
    this.installedPkgsFn,
    this.managerOverride,
  });

  final String url;
  final VoidCallback onRemove;

  /// Live search query — filters the fetched entries; a non-empty query also
  /// forces the section open so matches are visible.
  final String query;
  final Future<List<AniyomiRepoEntry>> Function(String url)? fetchIndexFn;
  final Future<void> Function(AniyomiRepoEntry entry)? installFn;
  final Future<void> Function(String pkg)? uninstallFn;
  final bool Function(String pkg)? installedPkgsFn;

  /// Test seam: overrides the live `sl<MihonManager>()` lookup used for the
  /// repo's update-check / update-all / badge behavior.
  final MihonManager? managerOverride;

  @override
  State<_MihonRepoSection> createState() => _MihonRepoSectionState();
}

class _MihonRepoSectionState extends State<_MihonRepoSection> {
  List<AniyomiRepoEntry>? _entries;
  bool _fetching = true;
  String? _fetchError;
  bool _expanded = true;
  bool _checking = false;
  bool _updating = false;

  // Local installed-state cache for instant UI feedback after install/uninstall.
  final Set<String> _installedPkgs = {};

  /// Null in widget tests that don't register it — the language filter is then
  /// simply off (every entry shows), so those tests keep asserting on the full
  /// list. In the app it's always registered.
  final MangaLangPrefs? _langPrefs =
      sl.isRegistered<MangaLangPrefs>() ? sl<MangaLangPrefs>() : null;

  /// Null when [MihonManager] isn't DI-registered (e.g. a widget test that
  /// builds this section directly without going through the app's injector).
  MihonManager? get _manager =>
      widget.managerOverride ??
      (sl.isRegistered<MihonManager>() ? sl<MihonManager>() : null);

  @override
  void initState() {
    super.initState();
    _langPrefs?.addListener(_onLangsChanged);
    _loadInstalledState();
    _fetchCatalog();
  }

  @override
  void dispose() {
    _langPrefs?.removeListener(_onLangsChanged);
    super.dispose();
  }

  void _onLangsChanged() {
    if (mounted) setState(() {});
  }

  void _loadInstalledState() {
    if (widget.installedPkgsFn != null) return;
    try {
      if (Hive.isBoxOpen(MihonExtensionService.installedBoxName)) {
        final box = Hive.box<dynamic>(MihonExtensionService.installedBoxName);
        _installedPkgs.addAll(box.keys.cast<String>());
      }
    } catch (_) {}
  }

  bool _isInstalled(String pkg) {
    if (widget.installedPkgsFn != null) return widget.installedPkgsFn!(pkg);
    if (_installedPkgs.contains(pkg)) return true;
    try {
      if (Hive.isBoxOpen(MihonExtensionService.installedBoxName)) {
        return Hive.box<dynamic>(
          MihonExtensionService.installedBoxName,
        ).containsKey(pkg);
      }
    } catch (_) {}
    return false;
  }

  Future<void> _fetchCatalog() async {
    try {
      final fn = widget.fetchIndexFn ?? MihonRepo.fetchIndex;
      final entries = await fn(widget.url);
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

  Future<void> _confirmRemove(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Remove repo?', style: AppText.headline),
        content: Text(
          'Already-installed extensions from this repo stay installed. '
          'You can add the repo back later.',
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
    if (ok == true) widget.onRemove();
  }

  /// READ-ONLY check of this repo for extension updates via
  /// [MihonManager.checkRepoUpdates] (no download). Reports how many are
  /// available; the accent badge + "Update all" menu item then appear.
  Future<void> _checkForUpdates() async {
    final mgr = _manager;
    if (mgr == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _checking = true);
    try {
      final list = await mgr.checkRepoUpdates(widget.url);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              list.isEmpty
                  ? 'Up to date'
                  : '${list.length} update${list.length == 1 ? '' : 's'} available',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Installs a single entry, reporting whether it actually succeeded.
  ///
  /// [widget.installFn] is a test seam that returns `Future<void>` and throws
  /// on failure, so a non-throwing call always counts as success. The default
  /// path calls [MihonExtensionService.installFromRepo], which never throws
  /// and instead returns an empty list on failure — that emptiness is what we
  /// key success off of.
  Future<bool> _applyOne(AniyomiRepoEntry entry, MihonManager mgr) async {
    if (widget.installFn != null) {
      await widget.installFn!(entry);
      return true;
    }
    final providers = await MihonExtensionService().installFromRepo(
      entry,
      manager: mgr,
    );
    return providers.isNotEmpty;
  }

  /// Applies every pending update for this repo (re-installs each newer entry)
  /// via [widget.installFn] or the default [MihonExtensionService.installFromRepo].
  ///
  /// Only clears a package's pending update when its install actually
  /// succeeded — a failed download must keep reporting the source as
  /// outdated rather than silently clearing the badge.
  Future<void> _updateAll() async {
    final mgr = _manager;
    if (mgr == null || _updating) return;
    final messenger = ScaffoldMessenger.of(context);
    final updates = List<MihonUpdate>.from(mgr.updatesFor(widget.url));
    if (updates.isEmpty) return;
    setState(() => _updating = true);
    var done = 0;
    try {
      for (final u in updates) {
        try {
          if (await _applyOne(u.entry, mgr)) {
            mgr.clearUpdatesForPkg(u.pkg);
            done++;
          }
        } catch (_) {}
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text('Updated $done source${done == 1 ? '' : 's'}')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final searching = widget.query.trim().isNotEmpty;
    // While searching, a fully-loaded section with zero matches disappears
    // entirely (matching the CloudStream screen's behavior).
    if (searching &&
        !_fetching &&
        _fetchError == null &&
        _filteredEntries.isEmpty) {
      return const SizedBox.shrink();
    }
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
          // ── Header ──────────────────────────────────────────────────────
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
                                _repoDisplayName,
                                style: AppText.headline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _fetching
                                    ? 'Loading…'
                                    : _fetchError != null
                                    ? 'Failed to load'
                                    : '${_entries?.length ?? 0} extension'
                                          '${(_entries?.length ?? 0) == 1 ? '' : 's'}',
                                style: AppText.caption.copyWith(
                                  color: _fetchError != null
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
                // "N updates" pill when this repo has installed extensions
                // with a newer version available (tap → update all). Hidden
                // entirely when the manager isn't DI-registered (tests).
                Builder(
                  builder: (context) {
                    final mgr = _manager;
                    if (mgr == null) return const SizedBox.shrink();
                    return AnimatedBuilder(
                      animation: mgr,
                      builder: (context, _) {
                        final n = mgr.updatesFor(widget.url).length;
                        if (n == 0) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(right: 2),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _updateAll,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.accent.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                n == 1 ? '1 update' : '$n updates',
                                style: AppText.caption.copyWith(
                                  color: AppColors.accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert,
                    color: AppColors.textSecondary,
                  ),
                  color: AppColors.surface2,
                  onSelected: (v) {
                    if (v == 'refresh') _fetchCatalog();
                    if (v == 'check' && !_checking) _checkForUpdates();
                    if (v == 'update_all') _updateAll();
                    if (v == 'remove') _confirmRemove(context);
                  },
                  itemBuilder: (_) {
                    // Null manager (not DI-registered) reads as "no updates":
                    // "check" stays available, "update_all" stays hidden.
                    final mgr = _manager;
                    final pendingUpdates =
                        mgr?.updatesFor(widget.url) ?? const [];
                    return [
                      PopupMenuItem(
                        value: 'refresh',
                        child: Text(
                          'Refresh',
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'check',
                        enabled: !_checking,
                        child: Text(
                          _checking
                              ? 'Checking for updates…'
                              : 'Check for updates',
                          style: AppText.body.copyWith(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (pendingUpdates.isNotEmpty)
                        PopupMenuItem(
                          value: 'update_all',
                          child: Text(
                            'Update all '
                            '(${pendingUpdates.length})',
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
                    ];
                  },
                ),
              ],
            ),
          ),
          // ── Collapsible extension list (search forces it open) ───────────
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !(_expanded || searching)
                ? const SizedBox(width: double.infinity)
                : _buildBody(),
          ),
        ],
      ),
    );
  }

  /// The fetched entries filtered by the live search query and the language
  /// picker (when registered — off in tests, so every entry shows there).
  List<AniyomiRepoEntry> get _filteredEntries {
    final enabled = _langPrefs == null
        ? null
        : (_langPrefs.enabled ?? defaultSourceLangs());
    return [
      for (final e in _entries ?? const <AniyomiRepoEntry>[])
        if (sourceSearchMatches(widget.query, e.name, e.lang) &&
            (enabled == null || sourceLangVisible(e.lang, enabled)))
          e,
    ];
  }

  Widget _buildBody() {
    if (_fetching) {
      return Padding(
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
      );
    }
    if (_fetchError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'Failed to load: $_fetchError',
          textAlign: TextAlign.center,
          style: AppText.caption.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    final entries = _filteredEntries;
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'No extensions found in this repo.',
          textAlign: TextAlign.center,
          style: AppText.caption,
        ),
      );
    }
    // keiyoushi ships 1,300+ extensions in one repo, so an eager Column here
    // meant ~2,700 widgets built in a single frame. Capping the height gives
    // the ListView a real viewport, so only the visible rows get built; a repo
    // whose list is shorter than the cap still sizes to its content and looks
    // exactly like it did before.
    //
    // ponytail: a capped inner scroller rather than slivers — hoisting the rows
    // into the tab's scroll view would mean rewriting it as a CustomScrollView
    // and giving up the collapse animation. Worth doing if nested scrolling
    // with several large repos open turns out to annoy people.
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: ListView.builder(
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final entry = entries[i];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Divider(
                height: 0.5,
                thickness: 0.5,
                color: AppColors.hairline,
              ),
              _MihonExtensionRow(
                entry: entry,
                installed: _isInstalled(entry.pkg),
                installFn: widget.installFn,
                uninstallFn: widget.uninstallFn,
                onInstalled: () => setState(() => _installedPkgs.add(entry.pkg)),
                onUninstalled: () =>
                    setState(() => _installedPkgs.remove(entry.pkg)),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// One extension row
// ---------------------------------------------------------------------------

class _MihonExtensionRow extends StatefulWidget {
  const _MihonExtensionRow({
    required this.entry,
    required this.installed,
    required this.onInstalled,
    required this.onUninstalled,
    this.installFn,
    this.uninstallFn,
  });

  final AniyomiRepoEntry entry;
  final bool installed;
  final VoidCallback onInstalled;
  final VoidCallback onUninstalled;
  final Future<void> Function(AniyomiRepoEntry entry)? installFn;
  final Future<void> Function(String pkg)? uninstallFn;

  @override
  State<_MihonExtensionRow> createState() => _MihonExtensionRowState();
}

class _MihonExtensionRowState extends State<_MihonExtensionRow> {
  bool _busy = false;

  AniyomiRepoEntry get _entry => widget.entry;

  String get _meta {
    final parts = <String>[
      if (_entry.lang.isNotEmpty) _entry.lang,
      if (_entry.version.isNotEmpty) 'v${_entry.version}',
    ];
    return parts.isEmpty ? 'mihon' : parts.join(' • ');
  }

  Future<void> _install() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (widget.installFn != null) {
        await widget.installFn!(_entry);
      } else {
        final mgr = GetIt.instance.isRegistered<MihonManager>()
            ? GetIt.instance.get<MihonManager>()
            : null;
        final providers = await MihonExtensionService().installFromRepo(
          _entry,
          manager: mgr,
        );
        // installFromRepo never throws — it returns an empty list on failure.
        // Treat "no source loaded" as a failure so we don't mislabel "Installed".
        if (providers.isEmpty) {
          throw Exception(
            'No source loaded — the extension may be incompatible or the '
            'download failed.',
          );
        }
      }
      widget.onInstalled();
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Installed ${_entry.name}')));
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Install failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Uninstall ${_entry.name}?', style: AppText.headline),
        content: Text(
          'This removes the extension from your installed sources.',
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
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (widget.uninstallFn != null) {
        await widget.uninstallFn!(_entry.pkg);
      } else {
        await _defaultUninstall();
      }
      widget.onUninstalled();
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Uninstalled ${_entry.name}')));
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Uninstall failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _defaultUninstall() async {
    // Remove from installed box.
    try {
      if (Hive.isBoxOpen(MihonExtensionService.installedBoxName)) {
        await Hive.box<dynamic>(
          MihonExtensionService.installedBoxName,
        ).delete(_entry.pkg);
      }
    } catch (_) {}
    // Remove from the manager so the source disappears from the picker.
    // Unlike AniyomiManager (whose store is Map<String, BaseProvider> and so
    // needs an `is AniyomiProvider` narrowing check), MihonManager._sources is
    // already typed Map<String, MihonProvider> — removeWhere's predicate
    // takes a MihonProvider directly, so no type check is needed here.
    if (GetIt.instance.isRegistered<MihonManager>()) {
      GetIt.instance.get<MihonManager>().removeWhere(
        (p) => p.pkg == _entry.pkg,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final installed = widget.installed;
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
                        _entry.name,
                        style: AppText.headline.copyWith(fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_entry.nsfw) ...[
                      const SizedBox(width: 8),
                      _NsfwBadge(),
                    ],
                  ],
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
// NSFW badge (local copy; mirrors the one in aniyomi_repo_tab.dart /
// sources_screen.dart)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Test seam: builds a bare _MihonRepoSection with an injected MihonManager
// so widget tests can drive checkRepoUpdates()/updatesFor() without touching
// sl<MihonManager>() or the network.
// ---------------------------------------------------------------------------

@visibleForTesting
Widget debugMihonRepoSection({
  required String url,
  required MihonManager manager,
  required Future<List<AniyomiRepoEntry>> Function(String url) fetchIndexFn,
  Future<void> Function(AniyomiRepoEntry entry)? installFn,
  bool Function(String pkg)? installedPkgsFn,
}) => _MihonRepoSection(
  url: url,
  onRemove: () {},
  fetchIndexFn: fetchIndexFn,
  installFn: installFn,
  installedPkgsFn: installedPkgsFn,
  managerOverride: manager,
);
