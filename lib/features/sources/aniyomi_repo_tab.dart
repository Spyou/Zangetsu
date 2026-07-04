import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:hive/hive.dart';

import '../../core/aniyomi/aniyomi_extension_service.dart';
import '../../core/aniyomi/aniyomi_provider.dart';
import '../../core/aniyomi/aniyomi_repo.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import 'aniyomi_recommended_repos.dart';

/// Hive box name for persisted Aniyomi repo URLs.
const String kAniyomiReposBoxName = 'aniyomi_repos';

// ---------------------------------------------------------------------------
// Public add-repo dialog (also used by the TV variant and tests)
// ---------------------------------------------------------------------------

/// Dialog for adding an Aniyomi extension repository.
///
/// Returns the chosen repo URL (base URL without `/index.min.json`) via
/// [Navigator.pop(context, url)] when the user picks a recommendation or
/// submits the URL field.  Returns null on cancel.
///
/// [alreadyAddedUrls] marks repos that have already been added so they show
/// an "Added" label instead of an "Add" button.
class AniyomiAddRepoDialog extends StatefulWidget {
  const AniyomiAddRepoDialog({super.key, this.alreadyAddedUrls = const {}});

  final Set<String> alreadyAddedUrls;

  @override
  State<AniyomiAddRepoDialog> createState() => _AniyomiAddRepoDialogState();
}

class _AniyomiAddRepoDialogState extends State<AniyomiAddRepoDialog> {
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

  Widget _recommendedTile(
    BuildContext context,
    ({String name, String desc, String url}) repo,
  ) {
    final added = widget.alreadyAddedUrls.contains(repo.url);
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
              style:
                  AppText.caption.copyWith(color: AppColors.textSecondary),
            )
          else
            OutlinedButton(
              onPressed: () => Navigator.pop(context, repo.url),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accent,
                side: BorderSide(
                    color: AppColors.accent.withValues(alpha: 0.6)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
      title: Text('Add Aniyomi repo', style: AppText.headline),
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
              '"/index.min.json" automatically.',
              style: AppText.caption,
            ),
            if (kRecommendedAniyomiRepos.isNotEmpty) ...[
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
              for (final r in kRecommendedAniyomiRepos)
                _recommendedTile(context, r),
            ],
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

/// The content of the Aniyomi tab: one collapsible card per tracked repo,
/// each listing its extensions with Install / Installed actions.
///
/// [repoUrls] is the list of tracked repo base URLs (owned by the caller,
/// e.g. [_SourcesViewState]).  [onRemoveRepo] removes a URL from that list.
///
/// All four optional callbacks are injectable seams for widget tests so the
/// network, native channel, and Hive are never touched:
/// - [fetchIndexFn]: replaces [AniyomiRepo.fetchIndex].
/// - [installFn]: replaces [AniyomiExtensionService.installFromRepo].
/// - [uninstallFn]: replaces the default uninstall logic.
/// - [installedPkgsFn]: replaces the Hive-box installed check.
class AniyomiRepoTab extends StatelessWidget {
  const AniyomiRepoTab({
    super.key,
    required this.repoUrls,
    required this.onRemoveRepo,
    this.fetchIndexFn,
    this.installFn,
    this.uninstallFn,
    this.installedPkgsFn,
  });

  final List<String> repoUrls;
  final void Function(String url) onRemoveRepo;

  final Future<List<AniyomiRepoEntry>> Function(String url)? fetchIndexFn;
  final Future<void> Function(AniyomiRepoEntry entry)? installFn;
  final Future<void> Function(String pkg)? uninstallFn;
  final bool Function(String pkg)? installedPkgsFn;

  @override
  Widget build(BuildContext context) {
    if (repoUrls.isEmpty) {
      return const EmptyState(
        icon: Icons.extension_outlined,
        message:
            'No Aniyomi repos added yet.\nTap "Add Aniyomi repo" to add one.',
      );
    }
    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () async {},
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        itemCount: repoUrls.length,
        itemBuilder: (_, i) => _AniyomiRepoSection(
          url: repoUrls[i],
          onRemove: () => onRemoveRepo(repoUrls[i]),
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

class _AniyomiRepoSection extends StatefulWidget {
  const _AniyomiRepoSection({
    required this.url,
    required this.onRemove,
    this.fetchIndexFn,
    this.installFn,
    this.uninstallFn,
    this.installedPkgsFn,
  });

  final String url;
  final VoidCallback onRemove;
  final Future<List<AniyomiRepoEntry>> Function(String url)? fetchIndexFn;
  final Future<void> Function(AniyomiRepoEntry entry)? installFn;
  final Future<void> Function(String pkg)? uninstallFn;
  final bool Function(String pkg)? installedPkgsFn;

  @override
  State<_AniyomiRepoSection> createState() => _AniyomiRepoSectionState();
}

class _AniyomiRepoSectionState extends State<_AniyomiRepoSection> {
  List<AniyomiRepoEntry>? _entries;
  bool _fetching = true;
  String? _fetchError;
  bool _expanded = true;

  // Local installed-state cache for instant UI feedback after install/uninstall.
  final Set<String> _installedPkgs = {};

  @override
  void initState() {
    super.initState();
    _loadInstalledState();
    _fetchCatalog();
  }

  void _loadInstalledState() {
    if (widget.installedPkgsFn != null) return;
    try {
      if (Hive.isBoxOpen(AniyomiExtensionService.installedBoxName)) {
        final box = Hive.box<dynamic>(AniyomiExtensionService.installedBoxName);
        _installedPkgs.addAll(box.keys.cast<String>());
      }
    } catch (_) {}
  }

  bool _isInstalled(String pkg) {
    if (widget.installedPkgsFn != null) return widget.installedPkgsFn!(pkg);
    if (_installedPkgs.contains(pkg)) return true;
    try {
      if (Hive.isBoxOpen(AniyomiExtensionService.installedBoxName)) {
        return Hive.box<dynamic>(AniyomiExtensionService.installedBoxName)
            .containsKey(pkg);
      }
    } catch (_) {}
    return false;
  }

  Future<void> _fetchCatalog() async {
    try {
      final fn = widget.fetchIndexFn ?? AniyomiRepo.fetchIndex;
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
          // ── Header ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _expanded = !_expanded),
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
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert,
                    color: AppColors.textSecondary,
                  ),
                  color: AppColors.surface2,
                  onSelected: (v) {
                    if (v == 'refresh') _fetchCatalog();
                    if (v == 'remove') _confirmRemove(context);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'refresh',
                      child: Text(
                        'Refresh',
                        style: AppText.body
                            .copyWith(color: AppColors.textPrimary),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      child: Text(
                        'Remove repo',
                        style: AppText.body
                            .copyWith(color: AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // ── Collapsible extension list ───────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : _buildBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_fetching) {
      return const Padding(
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
    final entries = _entries ?? [];
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in entries) ...[
          const Divider(
            height: 0.5,
            thickness: 0.5,
            color: AppColors.hairline,
          ),
          _AniyomiExtensionRow(
            entry: entry,
            installed: _isInstalled(entry.pkg),
            installFn: widget.installFn,
            uninstallFn: widget.uninstallFn,
            onInstalled: () =>
                setState(() => _installedPkgs.add(entry.pkg)),
            onUninstalled: () =>
                setState(() => _installedPkgs.remove(entry.pkg)),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// One extension row
// ---------------------------------------------------------------------------

class _AniyomiExtensionRow extends StatefulWidget {
  const _AniyomiExtensionRow({
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
  State<_AniyomiExtensionRow> createState() => _AniyomiExtensionRowState();
}

class _AniyomiExtensionRowState extends State<_AniyomiExtensionRow> {
  bool _busy = false;

  AniyomiRepoEntry get _entry => widget.entry;

  String get _meta {
    final parts = <String>[
      if (_entry.lang.isNotEmpty) _entry.lang,
      if (_entry.version.isNotEmpty) 'v${_entry.version}',
    ];
    return parts.isEmpty ? 'aniyomi' : parts.join(' • ');
  }

  Future<void> _install() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (widget.installFn != null) {
        await widget.installFn!(_entry);
      } else {
        final mgr = GetIt.instance.isRegistered<AniyomiManager>()
            ? GetIt.instance.get<AniyomiManager>()
            : null;
        final providers =
            await AniyomiExtensionService().installFromRepo(_entry, manager: mgr);
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
      if (Hive.isBoxOpen(AniyomiExtensionService.installedBoxName)) {
        await Hive.box<dynamic>(AniyomiExtensionService.installedBoxName)
            .delete(_entry.pkg);
      }
    } catch (_) {}
    // Remove from the manager so the source disappears from the picker.
    if (GetIt.instance.isRegistered<AniyomiManager>()) {
      GetIt.instance.get<AniyomiManager>().removeWhere(
            (p) => p is AniyomiProvider && p.info.pkg == _entry.pkg,
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
                    color: AppColors.textSecondary.withValues(alpha: 0.4)),
                minimumSize: const Size(96, 36),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
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
// NSFW badge (local copy; mirrors the one in sources_screen.dart)
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
