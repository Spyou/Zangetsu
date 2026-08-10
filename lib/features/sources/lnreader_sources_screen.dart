import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/lnreader/lnreader_extension_service.dart';
import '../../core/lnreader/lnreader_manager.dart';
import '../../core/lnreader/novel_lang_prefs.dart';
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

  final _langPrefs = sl<NovelLangPrefs>();

  @override
  void initState() {
    super.initState();
    _langPrefs.addListener(_onLangsChanged);
    _load();
  }

  @override
  void dispose() {
    _langPrefs.removeListener(_onLangsChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onLangsChanged() {
    if (mounted) setState(() {});
  }

  /// Distinct languages present in the loaded catalog.
  Set<String> get _availableLangs => _plugins.map((m) => m.lang).toSet();

  /// The languages actually shown: the user's saved selection, or — before
  /// they've configured anything — a device-aware default of English + the
  /// phone's language (plus "Other" so blank-lang plugins aren't hidden). Falls
  /// back to every language if none of those are in the catalog, so the first
  /// run is never empty.
  Set<String> get _enabledLangs => _langPrefs.enabled ?? _defaultLangs();

  // Device language code → the catalog's native-name `lang` value, so the
  // default can include the phone's language. The LNReader index labels
  // languages by native name, not ISO code, so we map the device's code to the
  // exact string it uses. Missing entries (e.g. Arabic's LTR-marked value) just
  // fall back to English-only, which the user can widen from the sheet.
  static const _deviceNative = {
    'en': 'English', 'ru': 'Русский', 'es': 'Español', 'fr': 'Français',
    'tr': 'Türkçe', 'pt': 'Português', 'id': 'Bahasa Indonesia',
    'vi': 'Tiếng Việt', 'ja': '日本語', 'th': 'ไทย', 'uk': 'Українська',
    'pl': 'Polski', 'zh': '中文, 汉语, 漢語', 'ko': '조선말, 한국어',
  };

  Set<String> _defaultLangs() {
    final available = _availableLangs;
    final device =
        WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    final def = <String>{};
    if (available.contains('English')) def.add('English');
    final native = _deviceNative[device];
    if (native != null && available.contains(native)) def.add(native);
    // If neither English nor the phone's language is in the catalog, show
    // everything so the first run is never empty.
    return def.isEmpty ? available : def;
  }

  /// Display label for a `lang` value. The index already uses native names
  /// ('English', 'Русский', '日本語', 'Multi'…), so show them as-is — only ''
  /// becomes "Other". Strips the LTR mark a couple of entries carry.
  static String _langName(String lang) {
    if (lang.isEmpty) return 'Other';
    return lang.replaceAll('\u200e', '').trim(); // strip LTR mark (e.g. Arabic)
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
      appBar: AppBar(
        title: Text('LNReader', style: AppText.barTitle),
        actions: [
          // Only worth showing when the catalog actually spans more than one
          // language (otherwise there's nothing to filter).
          if (_state == _LoadState.loaded && _availableLangs.length > 1)
            IconButton(
              tooltip: 'Languages',
              icon: const Icon(Icons.language_rounded),
              onPressed: _openLanguageSheet,
            ),
        ],
      ),
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

  /// Multi-select language sheet — one row per language in the catalog (with its
  /// plugin count), toggling the [NovelLangPrefs] enabled set live. English
  /// first, then most-plugins first, with "Other" (blank lang) last.
  void _openLanguageSheet() {
    final counts = <String, int>{};
    for (final m in _plugins) {
      counts[m.lang] = (counts[m.lang] ?? 0) + 1;
    }
    final langs = counts.keys.toList()
      ..sort((a, b) {
        if (a == b) return 0;
        if (a.isEmpty) return 1; // "Other" last
        if (b.isEmpty) return -1;
        if (a == 'English') return -1; // English first
        if (b == 'English') return 1;
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0 ? byCount : _langName(a).compareTo(_langName(b));
      });

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (ctx, setSheet) {
              // Read through the same effective set the list uses (saved
              // selection, else the device-aware default).
              final enabled = _enabledLangs;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                    child: Row(
                      children: [
                        Text('Languages', style: AppText.headline),
                        const Spacer(),
                        Text(
                          '${enabled.where(counts.containsKey).length} of ${langs.length}',
                          style: AppText.caption
                              .copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final lang in langs)
                          CheckboxListTile(
                            value: enabled.contains(lang),
                            onChanged: (v) {
                              final next = {...enabled};
                              if (v ?? false) {
                                next.add(lang);
                              } else {
                                next.remove(lang);
                              }
                              _langPrefs.setEnabled(next);
                              setSheet(() {});
                            },
                            activeColor: AppColors.accent,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(_langName(lang)),
                            secondary: Text(
                              '${counts[lang]}',
                              style: AppText.caption
                                  .copyWith(color: AppColors.textTertiary),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _list() {
    final installedIds =
        sl<LnReaderExtensionService>().installed().map((m) => m.id).toSet();
    final enabled = _enabledLangs;
    final filtered = _plugins
        .where((m) =>
            enabled.contains(m.lang) &&
            sourceSearchMatches(_query, m.name, m.lang))
        .toList();
    // Distinguish "your language filter hid everything" from "nothing here".
    final hiddenByLang = _query.trim().isEmpty && _plugins.isNotEmpty;

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
                  icon: hiddenByLang
                      ? Icons.language_rounded
                      : Icons.menu_book_outlined,
                  message: _query.trim().isNotEmpty
                      ? 'No sources match "${_query.trim()}".'
                      : hiddenByLang
                          ? 'No sources for the selected languages.\nTap the language button to add more.'
                          : 'No novel sources available.',
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
