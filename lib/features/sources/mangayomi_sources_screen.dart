import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/i18n/source_languages.dart';
import '../../core/mangayomi/mangayomi_manager.dart';
import '../../core/prefs/source_lang_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/source_icon_tile.dart';
import '../../core/ui/states.dart';
import 'package:AniAura_source_bridge/AniAura_source_bridge.dart';

import 'source_language_sheet.dart';
import 'source_prefs_screen.dart';
import 'sources_search_field.dart';

import '../../core/models/source_pref.dart';
import '../../l10n/l10n.dart';

class MangayomiSourcesScreen extends StatefulWidget {
  const MangayomiSourcesScreen({super.key});

  @override
  State<MangayomiSourcesScreen> createState() => _MangayomiSourcesScreenState();
}

class _MangayomiSourcesScreenState extends State<MangayomiSourcesScreen>
    with TickerProviderStateMixin {
  final _manager = sl<MangayomiManager>();
  final MangayomiLangPrefs? _langPrefs = sl.isRegistered<MangayomiLangPrefs>()
      ? sl<MangayomiLangPrefs>()
      : null;
  final _search = TextEditingController();
  late final TabController _tabs;
  late final TabController _typeTabs;
  final Set<String> _loading = {};
  final Map<Uri, Object> _errors = {};
  String _query = '';
  int _typeIndex = 0;
  bool _refreshing = false;
  int _lastUpdateNotifyCount = -1;
  final Set<Uri> _collapsedInstalledRepositories = {};
  final Set<Uri> _collapsedRepositories = {};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _typeTabs = TabController(length: 4, vsync: this);
    _manager.addListener(_changed);
    _langPrefs?.addListener(_changed);
    _refreshRepositories();
  }

  @override
  void dispose() {
    _manager.removeListener(_changed);
    _langPrefs?.removeListener(_changed);
    _search.dispose();
    _tabs.dispose();
    _typeTabs.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _onSearch(String value) {
    final query = value.trim().toLowerCase();
    if (_query == query) return;
    setState(() => _query = query);
  }

  MangayomiContentType? get _typeFilter => switch (_typeIndex) {
    1 => MangayomiContentType.video,
    2 => MangayomiContentType.manga,
    3 => MangayomiContentType.novel,
    _ => null,
  };

  Set<String> _presentLangs() => presentLangCodes([
    for (final item in _manager.installed) item.source,
    for (final repository in _manager.repositories)
      ..._manager.catalogueFor(repository),
  ], (source) => source.language);

  bool _sourceVisible(MangayomiSource source, Set<String> offered) {
    final type = _typeFilter;
    if (type != null && source.contentType != type) return false;
    final enabled = _langPrefs == null
        ? null
        : (_langPrefs.enabled ?? defaultSourceLangs());
    if (enabled == null) return true;
    return sourceLangVisible(source.language, enabled, offered: offered);
  }

  void _pickLanguages(bool isTv) {
    final prefs = _langPrefs;
    if (prefs == null) return;
    final present = _presentLangs();
    if (isTv) {
      showSourceLanguageSheetTv(context, prefs, present: present);
    } else {
      showSourceLanguageSheet(context, prefs, present: present);
    }
  }

  Future<void> _refreshRepositories({Uri? repository}) async {
    if (!mounted || _refreshing) return;
    setState(() => _refreshing = true);
    if (repository == null) {
      _errors.clear();
    } else {
      _errors.remove(repository);
    }
    await Future.wait([
      for (final url
          in repository == null ? _manager.repositories : [repository])
        _manager.refreshRepository(url).catchError((Object error) {
          _errors[url] = error;
          return const <MangayomiSource>[];
        }),
    ]);
    if (!mounted) return;
    setState(() => _refreshing = false);
    final count = _manager.updateCount;
    // Notify once per new update count, so repeated refreshes don't spam.
    if (count > 0 && count != _lastUpdateNotifyCount) {
      _lastUpdateNotifyCount = count;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mangayomi extension updates available')),
      );
    }
  }

  Future<void> _addRepository() async {
    final typeIndex = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('Add repository')),
            for (final (index, label, icon) in [
              (1, 'Anime', Icons.play_circle_outline_rounded),
              (2, 'Manga', Icons.menu_book_rounded),
              (3, 'Novel', Icons.auto_stories_rounded),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(context, index),
              ),
          ],
        ),
      ),
    );
    if (typeIndex == null || !mounted) return;
    var repositoryUrl = '';
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Add ${switch (typeIndex) {
            1 => 'Anime',
            2 => 'Manga',
            _ => 'Novel',
          }} repository',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paste the matching index link. Each category is saved separately.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              keyboardType: TextInputType.url,
              onChanged: (value) => repositoryUrl = value.trim(),
              decoration: InputDecoration(
                labelText: 'HTTPS repository URL',
                hintText: switch (typeIndex) {
                  1 => 'https://example.com/anime_index.json',
                  2 => 'https://example.com/manga_index.json',
                  _ => 'https://example.com/novel_index.json',
                },
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, repositoryUrl),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty) return;
    try {
      final repository = Uri.parse(value);
      final file = repository.pathSegments.lastOrNull;
      final validFile = switch (typeIndex) {
        1 => file == 'anime_index.json',
        2 => file == 'index.json' || file == 'manga_index.json',
        _ => file == 'novel_index.json',
      };
      if (!validFile) {
        throw FormatException(
          'Paste the ${switch (typeIndex) {
            1 => 'anime_index.json',
            2 => 'index.json or manga_index.json',
            _ => 'novel_index.json',
          }} link',
        );
      }
      final sources = await _manager.addRepository(repository);
      if (mounted) {
        _search.clear();
        setState(() {
          _query = '';
          _typeIndex = typeIndex;
          _errors.remove(repository);
          _collapsedRepositories.remove(repository);
        });
        _typeTabs.animateTo(typeIndex);
        _tabs.animateTo(1);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${sources.length} sources added')),
        );
      }
    } catch (error) {
      if (mounted) _error('Could not add repository: $error');
    }
  }

  Future<void> _removeRepository(Uri url) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove repository?'),
        content: const Text(
          'Installed sources stay on this device. Only this repository entry is removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    try {
      await _manager.removeRepository(url);
    } catch (error) {
      if (mounted) _error('Could not remove repository: $error');
    }
  }

  Future<void> _install(String key, Future<void> Function() action) async {
    setState(() => _loading.add(key));
    try {
      await action();
    } catch (error) {
      if (mounted) _error('Source action failed: $error');
    } finally {
      if (mounted) setState(() => _loading.remove(key));
    }
  }

  Future<void> _openSettings(MangayomiSource source) async {
    List<SourcePref> prefs;
    try {
      prefs = await _manager.sourcePreferences(source.key);
    } catch (_) {
      if (mounted) _error('Could not load source settings');
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (sheetContext) => prefs.isEmpty
            // Same shape as the other providers' settings screen: open the
            // screen, with "no settings" as its body — never a snackbar that
            // looks like a load failure.
            ? Scaffold(
                backgroundColor: AppColors.bg,
                appBar: AppBar(
                  backgroundColor: AppColors.bg,
                  title: Text(source.name, style: AppText.headline),
                ),
                body: EmptyState(
                  icon: Icons.tune,
                  message: sheetContext.l10n.thisSourceHasNoSettings,
                ),
              )
            : SourcePrefsScreen(
                title: source.name,
                prefs: prefs,
                write: (key, value) =>
                    _manager.setSourcePreference(source.key, key, value),
              ),
      ),
    );
  }

  Future<void> _uninstall(String key) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Uninstall source?'),
        content: const Text(
          'This removes its downloaded extension code. Saved list and history entries stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Uninstall'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    await _install(key, () => _manager.uninstall(key));
  }

  void _error(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
    final offeredLangs = _presentLangs();
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('Mangayomi', style: AppText.barTitle),
        actions: [
          if (_langPrefs != null)
            IconButton(
              tooltip: 'Languages',
              onPressed: () => _pickLanguages(isTv),
              icon: const Icon(Icons.language_rounded),
            ),
          if (isTv)
            IconButton(
              tooltip: 'Add repository',
              onPressed: _addRepository,
              icon: const Icon(Icons.add_rounded),
            ),
        ],
        bottom: TabBar(
          controller: _tabs,
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
      floatingActionButton: isTv
          ? null
          : FloatingActionButton.extended(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              onPressed: _addRepository,
              icon: const Icon(Icons.add_rounded),
              label: Text(
                'Add repository',
                style: AppText.button.copyWith(color: Colors.white),
              ),
            ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: TabBar(
                controller: _typeTabs,
                onTap: (index) => setState(() => _typeIndex = index),
                dividerColor: Colors.transparent,
                dividerHeight: 0,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  color: AppColors.accentSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                labelColor: AppColors.accent,
                unselectedLabelColor: AppColors.textSecondary,
                labelStyle: AppText.body.copyWith(fontWeight: FontWeight.w600),
                overlayColor: WidgetStateProperty.all(Colors.transparent),
                tabs: const [
                  Tab(height: 40, text: 'All'),
                  Tab(height: 40, text: 'Streaming'),
                  Tab(height: 40, text: 'Manga'),
                  Tab(height: 40, text: 'Novel'),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SourcesSearchField(
              controller: _search,
              hint: 'Search sources',
              onChanged: _onSearch,
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [_installedTab(), _repositoriesTab(offeredLangs)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _installedTab() {
    var installed = _manager.installed
        .where(
          (item) => sourceSearchMatches(
            _query,
            item.source.name,
            item.source.language,
          ),
        )
        .toList();
    if (_langPrefs != null) {
      installed = visibleInstalledSources(
        installed,
        _langPrefs.enabled ?? defaultSourceLangs(),
        pkgOf: (item) => item.source.name,
        langOf: (item) => item.source.language,
      );
    }
    final type = _typeFilter;
    if (type != null) {
      installed = installed
          .where((item) => item.source.contentType == type)
          .toList();
    }
    if (installed.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          EmptyState(
            icon: Icons.extension_outlined,
            message: _query.isEmpty
                ? 'No installed sources match the selected filters.'
                : 'No installed sources match "${_search.text.trim()}".',
          ),
        ],
      );
    }
    final groups = <Uri, List<InstalledMangayomiSource>>{};
    for (final item in installed) {
      groups.putIfAbsent(item.source.repository, () => []).add(item);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
        for (final group in groups.entries) _installedRepositoryGroup(group),
      ],
    );
  }

  Widget _installedRepositoryGroup(
    MapEntry<Uri, List<InstalledMangayomiSource>> group,
  ) {
    final expanded = !_collapsedInstalledRepositories.contains(group.key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() {
            if (expanded) {
              _collapsedInstalledRepositories.add(group.key);
            } else {
              _collapsedInstalledRepositories.remove(group.key);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: expanded ? 0 : -0.25,
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
                    _repositoryName(group.key).toUpperCase(),
                    style: AppText.overline.copyWith(
                      color: AppColors.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${group.value.length}',
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
          child: !(expanded || _query.isNotEmpty)
              ? const SizedBox(width: double.infinity)
              : Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < group.value.length; i++) ...[
                        if (i > 0)
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                        _sourceTile(
                          group.value[i].source,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Source settings',
                                icon: const Icon(Icons.tune_rounded, size: 20),
                                color: AppColors.textSecondary,
                                onPressed: () =>
                                    _openSettings(group.value[i].source),
                              ),
                              IconButton(
                                tooltip: 'Uninstall',
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 20,
                                ),
                                color: AppColors.textSecondary,
                                onPressed: () =>
                                    _uninstall(group.value[i].source.key),
                              ),
                            ],
                          ),
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

  Widget _repositoriesTab(Set<String> offered) {
    final filtered =
        _query.isNotEmpty || _typeFilter != null || _langPrefs != null;
    final repositories = _manager.repositories.where((repository) {
      if (_errors.containsKey(repository)) return true;
      if (!filtered) return true;
      // Only repos that actually hold matching sources — a Streaming-only
      // repo otherwise leaks into the Manga/Novel tabs (and the other way
      // around) with nothing but a "no sources here" card.
      return _manager
          .catalogueFor(repository)
          .any(
            (source) =>
                _sourceVisible(source, offered) &&
                sourceSearchMatches(_query, source.name, source.language),
          );
    }).toList();
    if (_manager.repositories.isEmpty || repositories.isEmpty) {
      final type = _typeFilter;
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          if (repositories.isEmpty && _refreshing)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            EmptyState(
              icon: _query.isNotEmpty
                  ? Icons.search_off_rounded
                  : Icons.dns_rounded,
              message: _manager.repositories.isEmpty
                  ? 'No repositories added yet. Add one to browse sources.'
                  : _query.isNotEmpty
                  ? 'No extensions match "${_search.text.trim()}".'
                  : type == null
                  ? 'No repositories match the selected languages.'
                  : 'No ${_contentType(type)} repositories match the selected filters.',
            ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _refreshRepositories,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          for (final repository in repositories)
            _repositorySection(repository, offered),
        ],
      ),
    );
  }

  Widget _repositorySection(Uri repository, Set<String> offered) {
    final error = _errors[repository];
    final allSources = _manager.catalogueFor(repository);
    final sources = allSources
        .where(
          (source) =>
              _sourceVisible(source, offered) &&
              sourceSearchMatches(_query, source.name, source.language),
        )
        .toList();
    final sourceTypes = allSources
        .map((source) => _contentType(source.contentType))
        .toSet();
    final expanded = !_collapsedRepositories.contains(repository);
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
                    onTap: () => setState(() {
                      if (expanded) {
                        _collapsedRepositories.add(repository);
                      } else {
                        _collapsedRepositories.remove(repository);
                      }
                    }),
                    child: Row(
                      children: [
                        AnimatedRotation(
                          turns: expanded ? 0 : -0.25,
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
                                _repositoryName(repository),
                                style: AppText.headline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                error != null
                                    ? 'Failed to load'
                                    : '${allSources.length} extensions'
                                          '${sourceTypes.isEmpty ? '' : ' · ${sourceTypes.join(', ')}'}',
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
                PopupMenuButton<String>(
                  tooltip: 'Repository actions',
                  color: AppColors.surface2,
                  icon: const Icon(
                    Icons.more_vert,
                    color: AppColors.textSecondary,
                  ),
                  onSelected: (action) {
                    if (action == 'check') {
                      _refreshRepositories(repository: repository);
                    }
                    if (action == 'remove') _removeRepository(repository);
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'check',
                      child: Text('Check for updates'),
                    ),
                    PopupMenuItem(
                      value: 'remove',
                      child: Text('Remove repository'),
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
            child: !(expanded || _query.isNotEmpty)
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (error != null)
                        ListTile(
                          title: const Text('Could not load repository'),
                          subtitle: Text(error.toString()),
                          trailing: IconButton(
                            tooltip: 'Retry',
                            onPressed: _refreshRepositories,
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        )
                      else if (_refreshing && allSources.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(20),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (sources.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _query.isEmpty
                                ? 'No sources match the selected filters'
                                : 'No matching sources',
                            style: AppText.caption,
                          ),
                        )
                      else
                        for (final source in sources) ...[
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                          _sourceTile(
                            source,
                            trailing: _catalogueAction(source),
                          ),
                        ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sourceTile(MangayomiSource source, {required Widget trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 12),
            child: SourceIconTile(
              name: source.name,
              icon: source.iconUrl?.toString(),
            ),
          ),
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
                    if (source.isNsfw) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.5),
                          ),
                        ),
                        child: Text(
                          context.l10n.nsfw,
                          style: AppText.overline.copyWith(
                            color: AppColors.accent,
                            fontWeight: FontWeight.w700,
                            fontSize: 9,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${_contentType(source.contentType)} · ${source.language}',
                  style: AppText.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }

  Widget _catalogueAction(MangayomiSource source) {
    final installed = _manager.get(source.key)?.source;
    if (installed != null &&
        !mangayomiVersionIsNewer(source.version, installed.version)) {
      return OutlinedButton(
        onPressed: () => _uninstall(source.key),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          side: BorderSide(
            color: AppColors.textSecondary.withValues(alpha: 0.4),
          ),
          minimumSize: const Size(96, 36),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: const Text('Installed'),
      );
    }
    final isUpdate = installed != null;
    return _actionButton(
      key: source.key,
      label: isUpdate ? 'Update' : 'Install',
      onPressed: () => _install(source.key, () => _manager.install(source)),
    );
  }

  Widget _actionButton({
    required String key,
    required String label,
    required VoidCallback onPressed,
  }) => _loading.contains(key)
      ? const SizedBox(
          width: 96,
          height: 36,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        )
      : FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            elevation: 0,
            minimumSize: const Size(96, 36),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(label),
        );

  static String _contentType(MangayomiContentType type) => switch (type) {
    MangayomiContentType.video => 'Streaming',
    MangayomiContentType.manga => 'Manga',
    MangayomiContentType.novel => 'Novel',
  };

  static String _repositoryName(Uri repository) =>
      repository.host == 'raw.githubusercontent.com' &&
          repository.pathSegments.length >= 2
      ? '${repository.pathSegments[0]}/${repository.pathSegments[1]}'
      : repository.host;
}
