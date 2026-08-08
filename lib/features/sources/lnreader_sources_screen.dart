import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/lnreader/lnreader_extension_service.dart';
import '../../core/lnreader/lnreader_manager.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import 'sources_search_field.dart';

/// Phone screen for the LNReader novel-source catalog. Unlike
/// `MihonSourcesScreen`/`AniyomiSourcesScreen`, LNReader has ONE pinned
/// catalog (`LnReaderExtensionService.indexUrl`) — no user-added repos — so
/// this screen is a single searchable list from `fetchIndex()`, not a
/// tabbed Installed/Repositories view.
class LnReaderSourcesScreen extends StatefulWidget {
  const LnReaderSourcesScreen({super.key});

  @override
  State<LnReaderSourcesScreen> createState() => _LnReaderSourcesScreenState();
}

enum _LoadState { loading, loaded, error }

class _LnReaderSourcesScreenState extends State<LnReaderSourcesScreen> {
  _LoadState _state = _LoadState.loading;
  List<LnReaderPluginMeta> _plugins = const [];
  Object? _error;

  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// [refresh] is true when called from `RefreshIndicator.onRefresh` — the
  /// list is already populated, so skip the full-page spinner and let the
  /// RefreshIndicator's own spinner show while the list stays mounted (mirrors
  /// `source_health_screen.dart`'s RefreshIndicator+ListView staying mounted
  /// through a refresh).
  Future<void> _load({bool refresh = false}) async {
    if (!refresh || _plugins.isEmpty) {
      setState(() => _state = _LoadState.loading);
    }
    try {
      final plugins = await sl<LnReaderExtensionService>().fetchIndex();
      if (!mounted) return;
      setState(() {
        _plugins = plugins;
        _state = _LoadState.loaded;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _state = _LoadState.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: Text('LNReader', style: AppText.barTitle)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SourcesSearchField(
              controller: _searchCtrl,
              onChanged: (q) => setState(() => _query = q),
              hint: 'Search novel sources',
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_state) {
      case _LoadState.loading:
        return Center(
          child: CircularProgressIndicator(color: AppColors.accent),
        );
      case _LoadState.error:
        return EmptyState(
          icon: Icons.error_outline,
          message: 'Couldn\'t load novel sources.\n$_error',
          actionLabel: 'Retry',
          onAction: _load,
        );
      case _LoadState.loaded:
        return _list();
    }
  }

  Widget _list() {
    final installedIds =
        sl<LnReaderExtensionService>().installed().map((m) => m.id).toSet();
    final filtered = _plugins
        .where((m) => sourceSearchMatches(_query, m.name, m.lang))
        .toList();

    // Always wrapped in RefreshIndicator + a scrollable child (even when
    // filtered is empty) so pull-to-refresh keeps working on an empty result.
    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () => _load(refresh: true),
      child: filtered.isEmpty
          ? ListView(
              padding: const EdgeInsets.fromLTRB(16, 48, 16, 24),
              children: [
                EmptyState(
                  icon: Icons.menu_book_outlined,
                  message: _query.trim().isEmpty
                      ? 'No novel sources available.'
                      : 'No sources match "${_query.trim()}".',
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < filtered.length; i++) ...[
                        if (i > 0)
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                        _LnReaderSourceRow(
                          key: ValueKey(filtered[i].id),
                          meta: filtered[i],
                          installed: installedIds.contains(filtered[i].id),
                          onChanged: () => setState(() {}),
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
// One catalog row
// ---------------------------------------------------------------------------

class _LnReaderSourceRow extends StatefulWidget {
  const _LnReaderSourceRow({
    super.key,
    required this.meta,
    required this.installed,
    required this.onChanged,
  });

  final LnReaderPluginMeta meta;
  final bool installed;

  /// Notifies the parent list to recompute `installed()` after a successful
  /// install/remove — the row itself only owns its own `_busy` flag.
  final VoidCallback onChanged;

  @override
  State<_LnReaderSourceRow> createState() => _LnReaderSourceRowState();
}

class _LnReaderSourceRowState extends State<_LnReaderSourceRow> {
  bool _busy = false;

  Future<void> _install() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await sl<LnReaderExtensionService>().install(widget.meta);
      widget.onChanged();
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Installed ${widget.meta.name}')));
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Install failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ponytail: no confirm dialog here (every sibling *Reader/*Mihon uninstall
  // row has one) — the brief calls this screen out as deliberately simpler
  // than Mihon/Aniyomi (single pinned catalog, no repo flow) and doesn't ask
  // for one. Add if novel-source uninstalls turn out to be a common misfire.
  Future<void> _remove() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await sl<LnReaderManager>().uninstall(widget.meta.id);
      widget.onChanged();
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Removed ${widget.meta.name}')));
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Remove failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = widget.meta;
    final host = Uri.parse(meta.site).host;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meta.name,
                  style: AppText.headline.copyWith(fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text('${meta.lang} · $host', style: AppText.caption),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_busy)
            SizedBox(
              width: 84,
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
          else if (widget.installed)
            OutlinedButton(
              onPressed: _remove,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                side: BorderSide(
                  color: AppColors.textSecondary.withValues(alpha: 0.4),
                ),
                minimumSize: const Size(84, 36),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Remove'),
            )
          else
            FilledButton(
              onPressed: _install,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                minimumSize: const Size(84, 36),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Install'),
            ),
        ],
      ),
    );
  }
}
