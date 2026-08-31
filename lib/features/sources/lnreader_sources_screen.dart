import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/hive/safe_box.dart';

import '../../core/di/injector.dart';
import '../../core/lnreader/lnreader_extension_service.dart';
import '../../core/lnreader/lnreader_manager.dart';
import '../../core/lnreader/novel_lang_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/states.dart';
import 'sources_search_field.dart';
import '../../l10n/l10n.dart';

/// Hive box name for persisted LNReader repo index URLs — the novel twin of
/// `kMihonReposBoxName` (`lib/features/sources/mihon_repo_tab.dart`).
const String kLnReaderReposBoxName = 'lnreader_repos';

/// Phone screen for the LNReader novel-source catalog. Structural (much
/// simplified) twin of `MihonSourcesScreen`/`mihon_repo_tab.dart`: repos are
/// user-added, each fetched via `LnReaderExtensionService.fetchIndex(url)` and
/// rendered as its own section.
///
/// Same Installed/Repositories `TabBar` shell as `MihonSourcesScreen` — the
/// Installed tab lists every installed plugin (with Remove), the
/// Repositories tab holds the add-repo FAB's targets: the tracked repo list,
/// each one's fetched catalog (Install per source), and the search +
/// language filter over that catalog. Unlike Mihon there's no update-check
/// machinery (LNReader has none yet — see `LnReaderManager.updateCount`) and
/// no per-source settings, so the Repositories tab is a flat list of repo
/// sections rather than Mihon's update-aware ones.
class LnReaderSourcesScreen extends StatefulWidget {
  const LnReaderSourcesScreen({super.key});

  @override
  State<LnReaderSourcesScreen> createState() => _LnReaderSourcesScreenState();
}

enum _LoadState { loading, loaded }

/// One repo's fetched catalog, or the error it failed with. Both null means
/// still in flight (never actually observed here — [_load] awaits every
/// repo before flipping [_LoadState.loaded], so by the time a section is
/// built its entry always has one or the other).
class _RepoCatalog {
  const _RepoCatalog({this.entries, this.error});
  final List<LnReaderPluginMeta>? entries;
  final Object? error;
}

class _LnReaderSourcesScreenState extends State<LnReaderSourcesScreen> {
  _LoadState _state = _LoadState.loading;
  List<String> _repoUrls = [];
  final Map<String, _RepoCatalog> _catalogs = {};

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

  /// Every plugin meta the tracked repos returned (successful repos only),
  /// flattened — feeds the language sheet and the default-language guess.
  List<LnReaderPluginMeta> get _allCatalogEntries => [
    for (final c in _catalogs.values) ...?c.entries,
  ];

  /// Distinct languages present across every fetched repo.
  Set<String> get _availableLangs =>
      _allCatalogEntries.map((m) => m.lang).toSet();

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
    return lang.replaceAll('‎', '').trim(); // strip LTR mark (e.g. Arabic)
  }

  /// Loads the tracked repo URLs, then fetches every repo's index in
  /// parallel — one failed repo doesn't block the others (its section just
  /// shows "Failed to load").
  ///
  /// [refresh] is true when called from `RefreshIndicator.onRefresh` (or
  /// right after adding a repo) — if repos are already loaded, skip the
  /// full-page spinner and let the RefreshIndicator's own spinner show while
  /// the list stays mounted (mirrors `source_health_screen.dart`'s
  /// RefreshIndicator+ListView staying mounted through a refresh).
  Future<void> _load({bool refresh = false}) async {
    if (!refresh || _repoUrls.isEmpty) {
      setState(() => _state = _LoadState.loading);
    }
    if (!Hive.isBoxOpen(kLnReaderReposBoxName)) {
      await openBoxSafely<String>(kLnReaderReposBoxName);
    }
    final urls = Hive.box<String>(kLnReaderReposBoxName).values.toList();
    final service = sl<LnReaderExtensionService>();
    final fetched = await Future.wait(urls.map((url) async {
      try {
        return MapEntry(url, _RepoCatalog(entries: await service.fetchIndex(url)));
      } catch (e) {
        return MapEntry(url, _RepoCatalog(error: e));
      }
    }));
    if (!mounted) return;
    setState(() {
      _repoUrls = urls;
      _catalogs
        ..clear()
        ..addEntries(fetched);
      _state = _LoadState.loaded;
    });
  }

  Future<void> _addRepo(String url) async {
    if (!Hive.isBoxOpen(kLnReaderReposBoxName)) {
      await openBoxSafely<String>(kLnReaderReposBoxName);
    }
    final box = Hive.box<String>(kLnReaderReposBoxName);
    if (box.values.contains(url)) return;
    await box.add(url);
    await _load(refresh: true);
  }

  Future<void> _removeRepo(String url) async {
    if (!Hive.isBoxOpen(kLnReaderReposBoxName)) return;
    final box = Hive.box<String>(kLnReaderReposBoxName);
    final key = box
        .toMap()
        .entries
        .where((e) => e.value == url)
        .map((e) => e.key)
        .firstOrNull;
    if (key != null) await box.delete(key);
    if (mounted) {
      setState(() {
        _repoUrls = box.values.toList();
        _catalogs.remove(url);
      });
    }
  }

  Future<void> _confirmRemoveRepo(String url) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(context.l10n.removeRepo, style: AppText.headline),
        content: Text(
          context.l10n.alreadyInstalledSourcesStay +
              context.l10n.youCanAddRepoBackLater,
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
    if (ok == true) await _removeRepo(url);
  }

  Future<void> _showAddRepoDialog() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const LnReaderAddRepoDialog(),
    );
    if (url == null || url.isEmpty) return;
    await _addRepo(url);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Text(context.l10n.lnreader, style: AppText.barTitle),
          actions: [
            // Only worth showing when the catalog actually spans more than one
            // language (otherwise there's nothing to filter).
            if (_state == _LoadState.loaded && _availableLangs.length > 1)
              IconButton(
                tooltip: context.l10n.languages,
                icon: const Icon(Icons.language_rounded),
                onPressed: _openLanguageSheet,
              ),
          ],
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
          onPressed: _showAddRepoDialog,
          icon: const Icon(Icons.add),
          label: Text(
            context.l10n.addRepository,
            style: AppText.button.copyWith(color: Colors.white),
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: SourcesSearchField(
                controller: _searchCtrl,
                onChanged: (q) => setState(() => _query = q),
                hint: context.l10n.searchNovelSources,
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _installedTab(),
                  _repositoriesTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Installed tab: every installed plugin (regardless of whether its repo is
  /// still tracked), each with a Remove action. Reuses `_LnReaderCatalogCard`/
  /// `_LnReaderSourceRow` — an installed entry always renders as a context.l10n.removeDownloadTooltip
  /// row, same as an installed catalog entry does today.
  Widget _installedTab() {
    final installed = sl<LnReaderExtensionService>()
        .installed()
        .where((m) => sourceSearchMatches(_query, m.name, m.lang))
        .toList();
    if (installed.isEmpty) {
      return EmptyState(
        icon: Icons.menu_book_outlined,
        message: _query.trim().isEmpty
            ? context.l10n.noSourcesInstalledYet
            : 'No installed sources match "${_query.trim()}".',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        _LnReaderCatalogCard(
          entries: installed,
          installedIds: installed.map((m) => m.id).toSet(),
          onChanged: () => setState(() {}),
          iconOnly: true, // Installed tab → compact trash icon
        ),
      ],
    );
  }

  Widget _repositoriesTab() {
    if (_state == _LoadState.loading) {
      return Center(child: CircularProgressIndicator(color: AppColors.accent));
    }
    return _repositoriesList();
  }

  /// Multi-select language sheet — one row per language across every fetched
  /// repo (with its plugin count), toggling the [NovelLangPrefs] enabled set
  /// live. English first, then most-plugins first, with "Other" (blank lang)
  /// last.
  void _openLanguageSheet() {
    final counts = <String, int>{};
    for (final m in _allCatalogEntries) {
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
                        Text(context.l10n.languages, style: AppText.headline),
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

  /// Repositories tab body: the tracked repo list, each with its fetched
  /// catalog, or the "no repos" empty state. Installed plugins live entirely
  /// in [_installedTab] now — a catalog entry that's installed still shows as
  /// a context.l10n.removeDownloadTooltip row here too (via [installedIds]), it just isn't given its
  /// own section.
  Widget _repositoriesList() {
    final installedIds =
        sl<LnReaderExtensionService>().installed().map((m) => m.id).toSet();
    final enabled = _enabledLangs;

    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () => _load(refresh: true),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          if (_repoUrls.isEmpty)
            EmptyState(
              icon: Icons.extension_outlined,
              message: 'No repositories added.\n'
                  'Add one to browse novel sources.',
            )
          else
            for (final url in _repoUrls)
              _LnReaderRepoSection(
                url: url,
                catalog: _catalogs[url],
                query: _query,
                enabledLangs: enabled,
                installedIds: installedIds,
                onRemove: () => _confirmRemoveRepo(url),
                onRefresh: () => _load(refresh: true),
                onChanged: () => setState(() {}),
              ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add-repo dialog — URL-field-only, structural twin of the (now
// recommendation-free) `MihonAddRepoDialog` in `mihon_repo_tab.dart`.
// ---------------------------------------------------------------------------

/// Dialog for adding an LNReader novel-source repository. Returns the chosen
/// index URL via [Navigator.pop(context, url)] when submitted, or null on
/// cancel.
class LnReaderAddRepoDialog extends StatefulWidget {
  const LnReaderAddRepoDialog({super.key});

  @override
  State<LnReaderAddRepoDialog> createState() => _LnReaderAddRepoDialogState();
}

class _LnReaderAddRepoDialogState extends State<LnReaderAddRepoDialog> {
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
      title: Text(context.l10n.addNovelRepo, style: AppText.headline),
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
                labelText: context.l10n.pluginIndexUrl,
                hintText: context.l10n.pluginIndexUrlHint,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.pluginIndexPasteHelp,
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

// ---------------------------------------------------------------------------
// One repo's catalog section
// ---------------------------------------------------------------------------

/// One tracked repo: a header (name, source count / failure, collapse
/// chevron, 3-dot menu) plus its catalog rows. Header/body chrome and
/// interaction is a structural twin of Mihon's `_MihonRepoSection`
/// (mihon_repo_tab.dart) — collapsible via the `expand_more` chevron, repo
/// actions (Refresh / Remove repository) live behind `more_vert` rather than
/// a bare close icon. [catalog] is still fetched and owned by the parent
/// screen, so a repo never fetches or errors twice for the same load
/// ([_LnReaderSourcesScreenState._load] fetches every repo in one parallel
/// pass) — [_expanded] is the only state this widget owns itself.
///
/// Entries are naturally scoped to their own repo here, so two repos sharing
/// a plugin id never render as one merged, ambiguous row — each repo just
/// shows its own copy in its own section (see the class doc on the id-
/// collision behavior for installs).
class _LnReaderRepoSection extends StatefulWidget {
  const _LnReaderRepoSection({
    required this.url,
    required this.catalog,
    required this.query,
    required this.enabledLangs,
    required this.installedIds,
    required this.onRemove,
    required this.onRefresh,
    required this.onChanged,
  });

  final String url;
  final _RepoCatalog? catalog;
  final String query;
  final Set<String> enabledLangs;
  final Set<String> installedIds;
  final VoidCallback onRemove;
  final VoidCallback onRefresh;
  final VoidCallback onChanged;

  @override
  State<_LnReaderRepoSection> createState() => _LnReaderRepoSectionState();
}

class _LnReaderRepoSectionState extends State<_LnReaderRepoSection> {
  bool _expanded = true;

  String get _displayName {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return widget.url;
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.length >= 2) return '${segs[0]}/${segs[1]}';
    return uri.host.isNotEmpty ? uri.host : widget.url;
  }

  List<LnReaderPluginMeta> get _filtered => [
    for (final m in widget.catalog?.entries ?? const <LnReaderPluginMeta>[])
      if (widget.enabledLangs.contains(m.lang) &&
          sourceSearchMatches(widget.query, m.name, m.lang))
        m,
  ];

  @override
  Widget build(BuildContext context) {
    final error = widget.catalog?.error;
    final filtered = _filtered;
    final searching = widget.query.trim().isNotEmpty;
    // While searching, a fully-loaded section with zero matches disappears
    // entirely (matches MihonRepoTab's behavior).
    if (searching && error == null && filtered.isEmpty) {
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
                                _displayName,
                                style: AppText.headline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                error != null
                                    ? context.l10n.failedToLoad
                                    : '${widget.catalog?.entries?.length ?? 0} source'
                                          '${(widget.catalog?.entries?.length ?? 0) == 1 ? '' : 's'}',
                                style: AppText.caption.copyWith(
                                  color: error != null
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
                    if (v == 'refresh') widget.onRefresh();
                    if (v == 'remove') widget.onRemove();
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'refresh',
                      child: Text(
                        context.l10n.refresh,
                        style: AppText.body.copyWith(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      child: Text(
                        context.l10n.removeRepository,
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
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !(_expanded || searching)
                ? const SizedBox(width: double.infinity)
                : _buildBody(error, filtered),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(Object? error, List<LnReaderPluginMeta> filtered) {
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Text(
          context.l10n.failedToLoadError('$error'),
          style: AppText.caption.copyWith(color: AppColors.textSecondary),
        ),
      );
    }
    if (filtered.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Text(context.l10n.noSourcesInThisRepo, style: AppText.caption),
      );
    }
    return _LnReaderCatalogCard(
      entries: filtered,
      installedIds: widget.installedIds,
      onChanged: widget.onChanged,
      bare: true, // already inside this section's own card
    );
  }
}

/// A rounded list of catalog rows, one per plugin. [bare] skips the outer
/// card decoration for callers (repo sections) that already provide one.
class _LnReaderCatalogCard extends StatelessWidget {
  const _LnReaderCatalogCard({
    required this.entries,
    required this.installedIds,
    required this.onChanged,
    this.bare = false,
    this.iconOnly = false,
  });

  final List<LnReaderPluginMeta> entries;
  final Set<String> installedIds;
  final VoidCallback onChanged;
  final bool bare;

  /// True for the Installed tab (compact trash icon); false for a repo's
  /// catalog (text Install/Uninstall buttons).
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final rows = Column(
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0 || bare)
            const Divider(height: 0.5, thickness: 0.5, color: AppColors.hairline),
          _LnReaderSourceRow(
            key: ValueKey(entries[i].id),
            meta: entries[i],
            installed: installedIds.contains(entries[i].id),
            onChanged: onChanged,
            iconOnly: iconOnly,
          ),
        ],
      ],
    );
    if (bare) return rows;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: rows,
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
    this.iconOnly = false,
  });

  final LnReaderPluginMeta meta;
  final bool installed;

  /// Installed tab uses the compact trash icon ([iconOnly] true); a repo's
  /// catalog uses text Install/Uninstall buttons like Mihon's repo tab.
  final bool iconOnly;

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
      // Installs (and any later re-install) key by plugin id alone, same as
      // `LnReaderExtensionService.install` always has — the last install of a
      // given id wins, whichever repo it came from. Acceptable: it just
      // overwrites the stored JS, never crashes.
      await sl<LnReaderExtensionService>().install(widget.meta);
      widget.onChanged();
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(context.l10n.installedName(widget.meta.name))));
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(context.l10n.installFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ponytail: no confirm dialog here (every sibling *Reader/*Mihon uninstall
  // row has one) — the brief calls this screen out as deliberately simpler
  // than Mihon/Aniyomi and doesn't ask for one. Add if novel-source
  // uninstalls turn out to be a common misfire.
  Future<void> _remove() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await sl<LnReaderManager>().uninstall(widget.meta.id);
      widget.onChanged();
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(context.l10n.removedName(widget.meta.name))));
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(context.l10n.removeFailed('$e'))));
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
              // Matches the footprint of whichever control this is standing
              // in for — the compact delete icon when installed, Mihon's
              // wider Install button otherwise.
              width: widget.installed && widget.iconOnly ? 40 : 100,
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
          else if (widget.installed && widget.iconOnly)
            // Installed tab: compact trash icon, mirroring Mihon's
            // `_MihonSourceRow` (LNReader plugins have no per-source settings,
            // so no `tune` icon alongside it).
            IconButton(
              tooltip: context.l10n.navTabsRemove,
              icon: const Icon(Icons.delete_outline_rounded, size: 20),
              color: AppColors.textSecondary,
              onPressed: _remove,
            )
          else if (widget.installed)
            // A repo's catalog: an installed source shows an context.l10n.uninstall text
            // button, matching Mihon's repo tab (`_MihonExtensionRow`).
            OutlinedButton(
              onPressed: _remove,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                minimumSize: const Size(100, 36),
                side: const BorderSide(color: AppColors.hairline),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(context.l10n.uninstall),
            )
          else
            // Mirrors Mihon's catalog Install control exactly
            // (`_MihonExtensionRow` in mihon_repo_tab.dart).
            FilledButton(
              onPressed: _install,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
                elevation: 0,
                minimumSize: const Size(96, 36),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(context.l10n.install),
            ),
        ],
      ),
    );
  }
}
