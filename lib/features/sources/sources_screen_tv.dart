import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../core/aniyomi/aniyomi_extension_service.dart';
import '../../core/aniyomi/aniyomi_provider.dart';
import '../../core/aniyomi/aniyomi_repo.dart';
import '../../core/di/injector.dart';
import '../../core/provider/base_provider.dart';
import '../../core/playback/playback_prefs.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/provider/provider_repo_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_back_button.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/states.dart';
import 'aniyomi_recommended_repos.dart';
import 'aniyomi_repo_tab.dart' show kAniyomiReposBoxName;
import 'bloc/sources_bloc.dart';
import 'bloc/sources_event.dart';
import 'bloc/sources_state.dart';
import 'source_settings_screen.dart';
import 'tv_recommended_aniyomi_repos.dart';
import 'tv_recommended_cs_repos.dart';

/// TV Providers screen. A single scrollable list with three collapsible
/// sections (Installed / Repos / CloudStream). Every interactive element —
/// section headers, enable toggles, settings gears, install/uninstall/update
/// chips — is wrapped in [TvFocusable] so a D-pad remote can reach it
/// independently.
///
/// Reuses [SourcesBloc] and all its events unchanged; navigation pushes the
/// same [SourceSettingsScreen] as the phone. Confirmation dialogs replace the
/// phone's [AlertDialog] touch buttons with [TvFocusable] buttons.
///
/// The phone [SourcesScreen] is byte-identical except for the single
/// `if (sl<AppMode>().isTv) return const SourcesScreenTv();` branch at the
/// top of [SourcesScreen.build].
class SourcesScreenTv extends StatelessWidget {
  const SourcesScreenTv({super.key, this.bloc});

  /// Optional pre-created bloc injected by tests so no GetIt setup is needed.
  /// At runtime this is always null — the screen creates its own bloc.
  final SourcesBloc? bloc;

  @override
  Widget build(BuildContext context) {
    const view = _TvSourcesView();
    final b = bloc;
    if (b != null) {
      return BlocProvider<SourcesBloc>.value(value: b, child: view);
    }
    return BlocProvider(
      create: (_) => SourcesBloc(
        registry: sl<ProviderRegistry>(),
        repos: sl<ProviderReposRegistry>(),
      ),
      child: view,
    );
  }
}

// ---------------------------------------------------------------------------
// Top-level view
// ---------------------------------------------------------------------------

class _TvSourcesView extends StatefulWidget {
  const _TvSourcesView();

  @override
  State<_TvSourcesView> createState() => _TvSourcesViewState();
}

class _TvSourcesViewState extends State<_TvSourcesView> {
  bool _installedExpanded = true;
  bool _reposExpanded = true;
  bool _csExpanded = true;
  bool _aniyomiExpanded = true;

  // ── Aniyomi repo state ────────────────────────────────────────────────────
  List<String> _aniyomiRepoUrls = [];

  @override
  void initState() {
    super.initState();
    _loadAniyomiRepos();
  }

  Future<void> _loadAniyomiRepos() async {
    if (Platform.isAndroid) {
      if (!Hive.isBoxOpen(kAniyomiReposBoxName)) {
        await Hive.openBox<String>(kAniyomiReposBoxName);
      }
      final box = Hive.box<String>(kAniyomiReposBoxName);
      if (mounted) setState(() => _aniyomiRepoUrls = box.values.toList());
    }
  }

  Future<void> _addAniyomiRepo(String url) async {
    if (!Hive.isBoxOpen(kAniyomiReposBoxName)) {
      await Hive.openBox<String>(kAniyomiReposBoxName);
    }
    final box = Hive.box<String>(kAniyomiReposBoxName);
    if (box.values.contains(url)) return;
    await box.add(url);
    if (mounted) setState(() => _aniyomiRepoUrls = box.values.toList());
  }

  Future<void> _showAddAniyomiRepoDialog() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _TvAniyomiAddRepoDialog(),
    );
    if (url == null || url.isEmpty) return;
    if (!mounted) return;
    await _addAniyomiRepo(url);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<void> _showAddRepoDialog() {
    final bloc = context.read<SourcesBloc>();
    return showDialog<void>(
      context: context,
      builder: (_) => _TvAddRepoDialog(bloc: bloc),
    );
  }

  Future<void> _showAddCsRepoDialog() async {
    final url = await showDialog<String>(
      context: context,
      builder: (_) => const _TvCsAddRepoDialog(),
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
                  ? 'Repo added.'
                  : 'Repo added — $count source${count == 1 ? '' : 's'} available.',
            ),
          ),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Failed to add repo: $e')));
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return BlocListener<SourcesBloc, SourcesState>(
      listenWhen: (a, b) =>
          b.notice != null &&
          (a.notice != b.notice || a.noticeSeq != b.noticeSeq),
      listener: (context, state) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(state.notice!)));
      },
      child: Scaffold(
        backgroundColor: AppColors.bg,
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Page title (wider TV margins) ──────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(48, 24, 48, 16),
                    child: Text('Providers', style: AppText.largeTitle),
                  ),
                  // ── Scrollable sections ────────────────────────────────────
                  Expanded(
                    child: ListView(
                  padding: const EdgeInsets.fromLTRB(40, 0, 40, 48),
                  children: [
                    // ── Installed ────────────────────────────────────────
                    _TvSectionHeader(
                      title: 'Installed',
                      expanded: _installedExpanded,
                      autofocus: true,
                      onTap: () => setState(
                        () => _installedExpanded = !_installedExpanded,
                      ),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: _installedExpanded
                          ? const _TvInstalledContent()
                          : const SizedBox(width: double.infinity),
                    ),
                    const SizedBox(height: 16),

                    // ── Repos ─────────────────────────────────────────────
                    _TvSectionHeader(
                      title: 'Repos',
                      expanded: _reposExpanded,
                      onTap: () =>
                          setState(() => _reposExpanded = !_reposExpanded),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: _reposExpanded
                          ? const _TvReposContent()
                          : const SizedBox(width: double.infinity),
                    ),
                    // "Add repo" action button — visible when Repos expanded.
                    AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: _reposExpanded
                          ? Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: TvFocusable(scale: 1.0, 
                                onTap: _showAddRepoDialog,
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
                                      const Icon(
                                        Icons.add,
                                        color: AppColors.accent,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Add repo',
                                        style: AppText.headline.copyWith(
                                          color: AppColors.accent,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          : const SizedBox(width: double.infinity),
                    ),
                    const SizedBox(height: 16),

                    // ── CloudStream + Aniyomi (Android only) ──────────────
                    if (Platform.isAndroid) ...[
                      _TvSectionHeader(
                        title: 'CloudStream',
                        expanded: _csExpanded,
                        onTap: () =>
                            setState(() => _csExpanded = !_csExpanded),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: _csExpanded
                            ? const _TvCloudStreamContent()
                            : const SizedBox(width: double.infinity),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: _csExpanded
                            ? Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: TvFocusable(scale: 1.0,
                                  onTap: _showAddCsRepoDialog,
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
                                        const Icon(
                                          Icons.add,
                                          color: AppColors.accent,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          'Add CS repo',
                                          style: AppText.headline.copyWith(
                                            color: AppColors.accent,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                      const SizedBox(height: 16),

                      // ── Aniyomi ─────────────────────────────────────────
                      _TvSectionHeader(
                        title: 'Aniyomi',
                        expanded: _aniyomiExpanded,
                        onTap: () =>
                            setState(() => _aniyomiExpanded = !_aniyomiExpanded),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: _aniyomiExpanded
                            ? _TvAniyomiContent(
                                repoUrls: _aniyomiRepoUrls,
                                onUrlsChanged: (urls) =>
                                    setState(() => _aniyomiRepoUrls = urls),
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: _aniyomiExpanded
                            ? Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: TvFocusable(
                                  scale: 1.0,
                                  onTap: _showAddAniyomiRepoDialog,
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
                                        const Icon(
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
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                    ],
                  ],
                ),
              ),
            ],
              ), // Column
            ), // SafeArea
            // D-pad-focusable back button at top-left.
            const Positioned(top: 8, left: 8, child: SafeArea(child: TvBackButton())),
          ], // Stack children
        ), // Stack (body)
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared section header widget
// ---------------------------------------------------------------------------

class _TvSectionHeader extends StatelessWidget {
  const _TvSectionHeader({
    required this.title,
    required this.expanded,
    required this.onTap,
    this.autofocus = false,
  });

  final String title;
  final bool expanded;
  final VoidCallback onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(scale: 1.0, 
      autofocus: autofocus,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
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
            const SizedBox(width: 8),
            Text(
              title.toUpperCase(),
              style: AppText.overline.copyWith(
                color: AppColors.textSecondary,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Installed section
// ---------------------------------------------------------------------------

class _TvInstalledContent extends StatelessWidget {
  const _TvInstalledContent();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SourcesBloc, SourcesState>(
      buildWhen: (a, b) => a.installed != b.installed || a.repos != b.repos,
      builder: (context, state) {
        final entries = state.installed;

        // Aniyomi + CloudStream installed groups at the top (Android only,
        // mirrors phone _InstalledTab which renders those groups as items 0+1).
        if (Platform.isAndroid) {
          final hasCs = sl<CloudStreamManager>().all.isNotEmpty;
          final hasAni = sl<AniyomiManager>().all.isNotEmpty;
          if (entries.isEmpty && !hasCs && !hasAni) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: EmptyState(
                icon: Icons.dns_rounded,
                message: 'No providers installed.',
              ),
            );
          }
        } else if (entries.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.dns_rounded,
              message: 'No providers installed.',
            ),
          );
        }

        // Group JS providers by origin repo (same logic as phone).
        final groups = <String, List<ProviderRegistryEntry>>{};
        for (final e in entries) {
          final key =
              e.originRepoUrl.isEmpty ? kBundledRepoUrl : e.originRepoUrl;
          groups.putIfAbsent(key, () => []).add(e);
        }
        final repoByUrl = {for (final r in state.repos) r.url: r};

        String nameFor(String repoUrl) {
          if (repoUrl == kBundledRepoUrl) return 'Built-in';
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
            // Aniyomi installed sources (Android only).
            if (Platform.isAndroid) const _TvAniyomiInstalledGroupList(),
            // CloudStream installed groups (Android only, mirrors phone).
            if (Platform.isAndroid) const _TvCsInstalledGroupList(),

            // JS provider groups.
            for (final key in keys)
              _TvInstalledGroup(
                title: nameFor(key),
                entries: groups[key]!
                  ..sort((a, b) {
                    final an =
                        a.displayName.isNotEmpty ? a.displayName : a.name;
                    final bn =
                        b.displayName.isNotEmpty ? b.displayName : b.name;
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

/// Mirrors the phone's _AniyomiInstalledGroup: lists every installed Aniyomi
/// source in a single D-pad-navigable group. Android-only.
class _TvAniyomiInstalledGroupList extends StatelessWidget {
  const _TvAniyomiInstalledGroupList();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<AniyomiManager>(),
      builder: (context, _) {
        final sources = sl<AniyomiManager>().all;
        if (sources.isEmpty) return const SizedBox.shrink();
        return BlocBuilder<ActiveSourceCubit, String>(
          builder: (context, activeId) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                child: Text(
                  'ANIYOMI',
                  style: AppText.overline.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
              for (final source in sources)
                _TvAniSourceRow(source: source, activeId: activeId),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _TvAniSourceRow extends StatefulWidget {
  const _TvAniSourceRow({required this.source, required this.activeId});

  final BaseProvider source;
  final String activeId;

  @override
  State<_TvAniSourceRow> createState() => _TvAniSourceRowState();
}

class _TvAniSourceRowState extends State<_TvAniSourceRow> {
  bool _hasSettings = false;

  @override
  void initState() {
    super.initState();
    _checkSettings();
  }

  @override
  void didUpdateWidget(_TvAniSourceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The element may be recycled for a different source when the list is
    // filtered/reordered (e.g. the NSFW toggle) — re-query so the gear
    // reflects the source now shown rather than a stale cached result.
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
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.displayName,
                      style: AppText.headline.copyWith(
                        color:
                            active ? AppColors.accent : AppColors.textPrimary,
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
              if (_hasSettings)
                TvFocusable(
                  scale: 1.0,
                  onTap: _openSettings,
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

/// Mirrors the phone's _CloudStreamGroup: lists every installed CS source
/// grouped by origin repo. Android-only (wrapped in _TvInstalledContent).
class _TvCsInstalledGroupList extends StatelessWidget {
  const _TvCsInstalledGroupList();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<CloudStreamManager>(),
      builder: (context, _) {
        final groups =
            sl<CloudStreamManager>().repoGroups.where((g) => g.sources.isNotEmpty);
        if (groups.isEmpty) return const SizedBox.shrink();
        return BlocBuilder<ActiveSourceCubit, String>(
          builder: (context, activeId) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final group in groups)
                _TvCsInstalledGroup(group: group, activeId: activeId),
            ],
          ),
        );
      },
    );
  }
}

class _TvCsInstalledGroup extends StatefulWidget {
  const _TvCsInstalledGroup({
    required this.group,
    required this.activeId,
  });
  final CsRepoGroup group;
  final String activeId;

  @override
  State<_TvCsInstalledGroup> createState() => _TvCsInstalledGroupState();
}

class _TvCsInstalledGroupState extends State<_TvCsInstalledGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final title =
        widget.group.name.isNotEmpty ? widget.group.name : 'CloudStream';
    final sources = widget.group.sources;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Group header — OK toggles expand.
        TvFocusable(scale: 1.0, 
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
                        _TvCsSourceRow(
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
class _TvCsSourceRow extends StatelessWidget {
  const _TvCsSourceRow({
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
            child: TvFocusable(scale: 1.0, 
              onTap: () {
                context.read<ActiveSourceCubit>().setSource(source.sourceId);
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    SnackBar(
                      content:
                          Text('Active source: ${source.displayName}'),
                    ),
                  );
              },
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
                    Text('cloudstream', style: AppText.caption),
                  ],
                ),
              ),
            ),
          ),
          // Enable/disable toggle — OK flips the state.
          TvFocusable(scale: 1.0, 
            onTap: () => manager.setEnabled(source.sourceId, !enabled),
            child: Switch.adaptive(
              value: enabled,
              activeThumbColor: AppColors.accent,
              onChanged: (v) => manager.setEnabled(source.sourceId, v),
            ),
          ),
          // Settings gear.
          TvFocusable(scale: 1.0, 
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SourceSettingsScreen(
                  sourceId: source.sourceId,
                  repoUrl: '',
                  displayName: source.displayName,
                ),
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.tune_rounded, size: 20,
                  color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Collapsible group of installed JS providers from one origin repo.
class _TvInstalledGroup extends StatefulWidget {
  const _TvInstalledGroup({
    required this.title,
    required this.entries,
    required this.state,
  });

  final String title;
  final List<ProviderRegistryEntry> entries;
  final SourcesState state;

  @override
  State<_TvInstalledGroup> createState() => _TvInstalledGroupState();
}

class _TvInstalledGroupState extends State<_TvInstalledGroup> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Group header — OK toggles expand.
        TvFocusable(scale: 1.0, 
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
                    widget.title.toUpperCase(),
                    style: AppText.overline.copyWith(
                      color: AppColors.textTertiary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${entries.length}',
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
                      for (var i = 0; i < entries.length; i++) ...[
                        if (i > 0)
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                        _TvInstalledRow(
                          entry: entries[i],
                          state: widget.state,
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

/// One installed JS provider row. Each action (update / enable toggle /
/// settings / remove) is an independent [TvFocusable] so the D-pad can
/// reach them individually.
class _TvInstalledRow extends StatelessWidget {
  const _TvInstalledRow({
    required this.entry,
    required this.state,
  });

  final ProviderRegistryEntry entry;
  final SourcesState state;

  String get _key =>
      ProviderRegistry.providerKey(entry.originRepoUrl, entry.name);

  Future<void> _confirmRemove(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final name =
        entry.displayName.isNotEmpty ? entry.displayName : entry.name;
    final ok = await _tvConfirm(
      context,
      title: 'Remove $name?',
      body: 'The provider will be removed from your installed sources.',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    bloc.add(SourceUninstalled(_key, displayName: name));
  }

  @override
  Widget build(BuildContext context) {
    final bundled = entry.isBundled;
    final name =
        entry.displayName.isNotEmpty ? entry.displayName : entry.name;
    final hasUpdate = state.hasUpdate(_key);
    final newVersion = state.manifestVersions[_key];
    final meta = hasUpdate
        ? 'repo • v${entry.version} → v$newVersion'
        : '${bundled ? 'built-in' : 'repo'} • v${entry.version}';

    return _RowFocusHalo(
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
                Text(
                  meta,
                  style: AppText.caption.copyWith(
                    color: hasUpdate ? AppColors.accent : null,
                  ),
                ),
              ],
            ),
          ),
          // Update button — present only when a newer version is available.
          if (hasUpdate)
            TvFocusable(scale: 1.0, 
              onTap: () =>
                  context.read<SourcesBloc>().add(SourceUpdated(_key)),
              child: Tooltip(
                message: 'Update to v$newVersion',
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(
                    Icons.download_rounded,
                    size: 20,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ),
          // Enable / disable switch — OK flips the toggle.
          TvFocusable(scale: 1.0, 
            onTap: () => context.read<SourcesBloc>().add(
              SourceEnabledToggled(_key, enabled: !entry.enabled),
            ),
            child: Switch.adaptive(
              value: entry.enabled,
              activeThumbColor: AppColors.accent,
              onChanged: (v) => context.read<SourcesBloc>().add(
                SourceEnabledToggled(_key, enabled: v),
              ),
            ),
          ),
          // Settings gear — OK pushes SourceSettingsScreen.
          TvFocusable(scale: 1.0, 
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SourceSettingsScreen(
                  sourceId: entry.name,
                  repoUrl: entry.originRepoUrl,
                  displayName: name,
                ),
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(
                Icons.tune_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          // Remove button — non-bundled sources only, OK shows confirm.
          if (!bundled)
            TvFocusable(scale: 1.0, 
              onTap: () => _confirmRemove(context),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
        ],
      ),
    ));
  }
}

/// Row-level focus halo for [_TvInstalledRow]. The source name sits on the far
/// left while its controls (enable switch / gear / remove) are individually
/// focusable on the right — so the small per-control highlight alone made it
/// hard to tell WHICH source you were on, or that a row was selectable at all.
/// This wraps the whole row and tints + outlines it whenever any control inside
/// holds focus, so the source you're acting on is obvious, on top of the
/// per-control highlight that shows the action. The border is always 2px (just
/// transparent when idle) so focus causes no layout shift.
class _RowFocusHalo extends StatefulWidget {
  const _RowFocusHalo({required this.child});
  final Widget child;

  @override
  State<_RowFocusHalo> createState() => _RowFocusHaloState();
}

class _RowFocusHaloState extends State<_RowFocusHalo> {
  bool _hasFocus = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      // Not a focus stop itself — it only observes whether a descendant control
      // (each its own TvFocusable) currently holds focus.
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (f != _hasFocus) setState(() => _hasFocus = f);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _hasFocus ? AppColors.accent.withValues(alpha: 0.10) : null,
          border: Border.all(
            color: _hasFocus
                ? AppColors.accent.withValues(alpha: 0.55)
                : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: widget.child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Repos section
// ---------------------------------------------------------------------------

class _TvReposContent extends StatelessWidget {
  const _TvReposContent();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SourcesBloc, SourcesState>(
      buildWhen: (a, b) => a.repos != b.repos || a.installed != b.installed,
      builder: (context, state) {
        final repos = state.repos;
        if (repos.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              message: 'No repos added yet.\nPress "Add repo" to add one.',
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final repo in repos)
              _TvRepoGroup(
                repo: repo,
                installedKeys: state.installedKeys,
                updatableKeys: state.updatableKeys,
              ),
          ],
        );
      },
    );
  }
}

class _TvRepoGroup extends StatefulWidget {
  const _TvRepoGroup({
    required this.repo,
    required this.installedKeys,
    required this.updatableKeys,
  });

  final ProviderRepo repo;
  final Set<String> installedKeys;
  final Set<String> updatableKeys;

  @override
  State<_TvRepoGroup> createState() => _TvRepoGroupState();
}

class _TvRepoGroupState extends State<_TvRepoGroup> {
  bool _expanded = true;

  ProviderRepo get repo => widget.repo;

  int get _updateCount => repo.sources
      .where(
        (s) => widget.updatableKeys
            .contains(ProviderRegistry.providerKey(repo.url, s.id)),
      )
      .length;

  Future<void> _removeRepo(BuildContext context) async {
    final bloc = context.read<SourcesBloc>();
    final ok = await _tvConfirm(
      context,
      title: 'Remove repo?',
      body:
          'Already-installed sources from "${repo.displayName}" stay installed. '
          'You can add the repo back later.',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    bloc.add(RepoRemoved(repo.url, displayName: repo.displayName));
  }

  @override
  Widget build(BuildContext context) {
    final updateCount = _updateCount;
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
          // ── Repo header row ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                // Expand/collapse toggle.
                TvFocusable(scale: 1.0, 
                  onTap: () => setState(() => _expanded = !_expanded),
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
                              color: updateCount > 0
                                  ? AppColors.accent
                                  : AppColors.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                // "Refresh" action.
                TvFocusable(scale: 1.0, 
                  onTap: () => context
                      .read<SourcesBloc>()
                      .add(RepoRefreshed(repo.url)),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(
                      'Refresh',
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
                // "Update all" action — only when updates exist.
                if (updateCount > 0)
                  TvFocusable(scale: 1.0, 
                    onTap: () => context
                        .read<SourcesBloc>()
                        .add(RepoUpdated(repo.url)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(
                        'Update all ($updateCount)',
                        style: AppText.caption.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                // "Remove" action.
                TvFocusable(scale: 1.0, 
                  onTap: () => _removeRepo(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    child: Text(
                      'Remove',
                      style:
                          AppText.caption.copyWith(color: AppColors.textSecondary),
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
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (repo.sources.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'No sources in this repo yet.',
                            textAlign: TextAlign.center,
                            style: AppText.caption,
                          ),
                        )
                      else
                        // Index-tracked loop so the first row gets autofocus,
                        // routing the D-pad there after the repo is added.
                        for (final (idx, source) in repo.sources
                            .where(
                              (s) =>
                                  !s.nsfw ||
                                  sl<PlaybackPrefs>().nsfwSources,
                            )
                            .indexed) ...[
                          const Divider(
                            height: 0.5,
                            thickness: 0.5,
                            color: AppColors.hairline,
                          ),
                          _TvRepoSourceRow(
                            repo: repo,
                            source: source,
                            installed: widget.installedKeys.contains(
                              ProviderRegistry.providerKey(
                                  repo.url, source.id),
                            ),
                            hasUpdate: widget.updatableKeys.contains(
                              ProviderRegistry.providerKey(
                                  repo.url, source.id),
                            ),
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
class _TvRepoSourceRow extends StatelessWidget {
  const _TvRepoSourceRow({
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
    final ok = await _tvConfirm(
      context,
      title: 'Uninstall ${source.name}?',
      body: 'The provider will be removed from your installed sources.',
      confirmLabel: 'Uninstall',
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
                    if (source.nsfw) ...[
                      const SizedBox(width: 8),
                      _NsfwBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${source.lang} • v${source.version}',
                  style: AppText.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (installed && hasUpdate)
            TvFocusable(scale: 1.0, 
              autofocus: autofocus,
              onTap: () =>
                  context.read<SourcesBloc>().add(SourceUpdated(_key)),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.download_rounded,
                        size: 16, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(
                      'Update',
                      style: AppText.caption.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (installed)
            TvFocusable(scale: 1.0, 
              autofocus: autofocus,
              onTap: () => _uninstall(context),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: AppColors.textSecondary.withValues(alpha: 0.4),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Installed',
                  style: AppText.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            )
          else
            TvFocusable(scale: 1.0, 
              autofocus: autofocus,
              onTap: () => context.read<SourcesBloc>().add(
                SourceInstalled(repo: repo, source: source),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Install',
                  style: AppText.caption.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CloudStream tab section (Android only)
// ---------------------------------------------------------------------------

/// Lists every loaded CloudStream repo with its full plugin catalog.
/// Only rendered on Android ([Platform.isAndroid] guard in _TvSourcesViewState).
class _TvCloudStreamContent extends StatelessWidget {
  const _TvCloudStreamContent();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sl<CloudStreamManager>(),
      builder: (context, _) {
        final groups = sl<CloudStreamManager>().repoGroups;
        if (groups.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: EmptyState(
              icon: Icons.cloud_outlined,
              message:
                  'No CloudStream repos added yet.\nPress "Add CS repo" to add one.',
            ),
          );
        }
        return BlocBuilder<ActiveSourceCubit, String>(
          builder: (context, activeId) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final group in groups)
                _TvCsRepoSection(group: group, activeId: activeId),
            ],
          ),
        );
      },
    );
  }
}

class _TvCsRepoSection extends StatefulWidget {
  const _TvCsRepoSection({required this.group, required this.activeId});
  final CsRepoGroup group;
  final String activeId;

  @override
  State<_TvCsRepoSection> createState() => _TvCsRepoSectionState();
}

class _TvCsRepoSectionState extends State<_TvCsRepoSection> {
  bool _expanded = true;
  bool _fetching = false;

  CsRepoGroup get group => widget.group;

  @override
  void initState() {
    super.initState();
    _maybeFetchCatalog();
  }

  @override
  void didUpdateWidget(covariant _TvCsRepoSection old) {
    super.didUpdateWidget(old);
    if (old.group.url != group.url) _maybeFetchCatalog();
  }

  void _maybeFetchCatalog() {
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
      ..showSnackBar(const SnackBar(content: Text('Checking for updates…')));
    try {
      final updates =
          await sl<CloudStreamManager>().checkRepoUpdates(group.url);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              updates.isEmpty
                  ? 'Up to date'
                  : '${updates.length} update(s) available',
            ),
          ),
        );
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Check failed: $e')));
    }
  }

  Future<void> _applyUpdates() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Updating…')));
    try {
      final count =
          await sl<CloudStreamManager>().updateRepo(group.url);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              count == 0 ? 'Already up to date' : 'Updated $count source(s)',
            ),
          ),
        );
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _removeRepo() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await _tvConfirm(
      context,
      title: 'Remove repository?',
      body: 'Remove this repository and its sources?',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    await sl<CloudStreamManager>().deleteRepo(group.url);
    messenger
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Removed')));
  }

  @override
  Widget build(BuildContext context) {
    final manager = sl<CloudStreamManager>();
    final isOther = group.url.isEmpty;
    final updates = isOther ? const <CsUpdate>[] : manager.updatesFor(group.url);
    final catalog = isOther ? _otherCatalog : group.catalog;
    final title = group.name.isNotEmpty ? group.name : 'CloudStream';
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
              ? (group.owner.isNotEmpty ? group.owner : 'cloudstream')
              : '$installedCount of ${catalog.length} installed'
                    '${group.owner.isNotEmpty ? ' • ${group.owner}' : ''}');

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
          // ── Repo header row ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                // Expand/collapse toggle.
                TvFocusable(scale: 1.0, 
                  onTap: () => setState(() => _expanded = !_expanded),
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
                // Update pill — apply all updates for this repo.
                if (updates.isNotEmpty)
                  TvFocusable(scale: 1.0, 
                    onTap: _applyUpdates,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        updates.length == 1
                            ? '1 update'
                            : '${updates.length} updates',
                        style: AppText.caption.copyWith(
                          color: AppColors.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                // "Check updates" — real repos only (no synthetic Other group).
                if (group.url.isNotEmpty)
                  TvFocusable(scale: 1.0, 
                    onTap: _checkUpdates,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text('Check updates',
                          style: AppText.caption
                              .copyWith(color: AppColors.textSecondary)),
                    ),
                  ),
                // "Remove repo" — real repos only.
                if (group.url.isNotEmpty)
                  TvFocusable(scale: 1.0, 
                    onTap: _removeRepo,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text('Remove',
                          style: AppText.caption
                              .copyWith(color: AppColors.textSecondary)),
                    ),
                  ),
              ],
            ),
          ),
          // ── Collapsible plugin catalog ──────────────────────────────────
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !_expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (catalog.isEmpty && _fetching)
                        const Padding(
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
                            'No installable sources found in this repo.',
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
                          _TvCsPluginRow(
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
/// action button — mirrors the phone's [_CsPluginRow].
/// [autofocus] should be true only for the first row so D-pad focus lands on
/// the Install button immediately after a repo is added and expanded.
class _TvCsPluginRow extends StatefulWidget {
  const _TvCsPluginRow({
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
  State<_TvCsPluginRow> createState() => _TvCsPluginRowState();
}

class _TvCsPluginRowState extends State<_TvCsPluginRow> {
  bool _busy = false;

  String get _meta {
    final parts = <String>[
      if (widget.plugin.language != null) widget.plugin.language!,
      if (widget.plugin.tvTypes.isNotEmpty)
        widget.plugin.tvTypes.join(' / '),
    ];
    return parts.isEmpty ? 'cloudstream' : parts.join(' • ');
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
          SnackBar(content: Text('Installed ${widget.plugin.name}')),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Install failed: $e')));
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
          SnackBar(content: Text('Updated ${widget.plugin.name}')),
        );
    } catch (e) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('Update failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uninstall() async {
    final ok = await _tvConfirm(
      context,
      title: 'Uninstall ${widget.plugin.name}?',
      body: 'This removes the source from your installed list.',
      confirmLabel: 'Uninstall',
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
          SnackBar(content: Text('Uninstalled ${widget.plugin.name}')),
        );
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
    final installed = widget.installed;
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
            const SizedBox(
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
            TvFocusable(scale: 1.0, 
              autofocus: widget.autofocus,
              onTap: _update,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Update → v${widget.update!.onlineVersion}',
                  style: AppText.caption.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
          else if (installed)
            TvFocusable(scale: 1.0, 
              autofocus: widget.autofocus,
              onTap: _uninstall,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: AppColors.textSecondary.withValues(alpha: 0.4),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Installed',
                  style: AppText.caption.copyWith(
                      color: AppColors.textSecondary),
                ),
              ),
            )
          else
            TvFocusable(scale: 1.0, 
              autofocus: widget.autofocus,
              onTap: _install,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Install',
                  style: AppText.caption.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Aniyomi section content for the TV screen
// ---------------------------------------------------------------------------

/// The body of the Aniyomi section on the TV Providers screen. Lists every
/// tracked repo (from Hive `'aniyomi_repos'`) with collapsible extension rows
/// matching what the phone [AniyomiRepoTab] shows.  Repos are fetched lazily;
/// an "Add Aniyomi repo" button is rendered separately by the parent scroll
/// list.
class _TvAniyomiContent extends StatelessWidget {
  const _TvAniyomiContent({
    required this.repoUrls,
    required this.onUrlsChanged,
  });

  final List<String> repoUrls;
  final ValueChanged<List<String>> onUrlsChanged;

  Future<void> _removeRepo(BuildContext context, String url) async {
    final ok = await _tvConfirm(
      context,
      title: 'Remove repo?',
      body:
          'Already-installed extensions stay installed. You can re-add the repo later.',
      confirmLabel: 'Remove',
    );
    if (!ok) return;
    if (!Hive.isBoxOpen(kAniyomiReposBoxName)) return;
    final box = Hive.box<String>(kAniyomiReposBoxName);
    final key = box.toMap().entries
        .where((e) => e.value == url)
        .map((e) => e.key)
        .firstOrNull;
    if (key != null) {
      await box.delete(key);
      onUrlsChanged(box.values.toList());
    }
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
          _TvAniyomiRepoSection(
            url: url,
            onRemove: () => _removeRepo(context, url),
          ),
      ],
    );
  }
}

class _TvAniyomiRepoSection extends StatefulWidget {
  const _TvAniyomiRepoSection({required this.url, required this.onRemove});

  final String url;
  final VoidCallback onRemove;

  @override
  State<_TvAniyomiRepoSection> createState() => _TvAniyomiRepoSectionState();
}

class _TvAniyomiRepoSectionState extends State<_TvAniyomiRepoSection> {
  List<AniyomiRepoEntry>? _entries;
  bool _fetching = true;
  String? _fetchError;
  bool _expanded = true;
  final Set<String> _installedPkgs = {};

  @override
  void initState() {
    super.initState();
    _loadInstalled();
    _fetch();
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
    final entries = _entries ?? [];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusable(
            scale: 1.0,
            onTap: () => setState(() => _expanded = !_expanded),
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
                  Expanded(
                    child: Text(
                      _repoDisplayName,
                      style: AppText.headline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    _fetching
                        ? 'Loading…'
                        : _fetchError != null
                        ? 'Error'
                        : '${entries.length} ext.',
                    style: AppText.caption,
                  ),
                  const SizedBox(width: 12),
                  TvFocusable(
                    scale: 1.0,
                    onTap: widget.onRemove,
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
          if (_expanded && !_fetching && entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                children: [
                  for (final entry in entries)
                    _TvAniyomiExtensionRow(
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

class _TvAniyomiExtensionRow extends StatefulWidget {
  const _TvAniyomiExtensionRow({
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
  State<_TvAniyomiExtensionRow> createState() =>
      _TvAniyomiExtensionRowState();
}

class _TvAniyomiExtensionRowState extends State<_TvAniyomiExtensionRow> {
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
    final ok = await _tvConfirm(
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
                          const _NsfwBadge(),
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
                const SizedBox(
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
                    color:
                        installed ? AppColors.textSecondary : AppColors.accent,
                    fontWeight: FontWeight.w700,
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
// Small shared widget: NSFW badge (mirrors phone's _NsfwBadge)
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
// TV confirm dialog (replaces AlertDialog touch buttons with TvFocusable)
// ---------------------------------------------------------------------------

/// Shows a D-pad-navigable confirmation dialog. [Cancel] gets autofocus
/// (safe default). Returns true only when the user confirms.
Future<bool> _tvConfirm(
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
                  TvFocusable(scale: 1.0, 
                    autofocus: true,
                    onTap: () => Navigator.pop(ctx, false),
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
                  const SizedBox(width: 4),
                  // Confirm action.
                  TvFocusable(scale: 1.0, 
                    onTap: () => Navigator.pop(ctx, true),
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
// Add-repo dialog (TV variant of phone's _AddRepoDialog)
// ---------------------------------------------------------------------------

class _TvAddRepoDialog extends StatefulWidget {
  const _TvAddRepoDialog({required this.bloc});
  final SourcesBloc bloc;

  @override
  State<_TvAddRepoDialog> createState() => _TvAddRepoDialogState();
}

class _TvAddRepoDialogState extends State<_TvAddRepoDialog> {
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
    final error = await widget.bloc
        .addRepo(url, customName: name.isEmpty ? null : name);
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
      title: Text('Add repo', style: AppText.headline),
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
            decoration: const InputDecoration(
              labelText: 'Custom name (optional)',
              hintText: "Leave blank to use the repo's own name",
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
            decoration: const InputDecoration(
              labelText: 'Manifest URL',
              hintText: 'https://.../index.json',
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "Paste the repo's index.json URL.",
            style: AppText.caption,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
          ],
        ],
      ),
      actions: [
        TvFocusable(scale: 1.0, 
          onTap: _loading ? () {} : () => Navigator.of(context).pop(),
          child: TextButton(
            onPressed: _loading ? null : () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ),
        TvFocusable(scale: 1.0, 
          onTap: _loading ? () {} : _submit,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: _loading ? null : _submit,
            child: _loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Add'),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Add-Aniyomi-repo dialog (TV variant of phone's AniyomiAddRepoDialog)
// ---------------------------------------------------------------------------

class _TvAniyomiAddRepoDialog extends StatefulWidget {
  const _TvAniyomiAddRepoDialog();

  @override
  State<_TvAniyomiAddRepoDialog> createState() =>
      _TvAniyomiAddRepoDialogState();
}

class _TvAniyomiAddRepoDialogState extends State<_TvAniyomiAddRepoDialog> {
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
            if (kRecommendedAniyomiRepos.isNotEmpty)
              TvRecommendedAniyomiRepos(
                onPick: (url) => Navigator.pop(context, url),
              ),
          ],
        ),
      ),
      actions: [
        TvFocusable(
          scale: 1.0,
          onTap: () => Navigator.of(context).pop(),
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ),
        TvFocusable(
          scale: 1.0,
          onTap: _submit,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: _submit,
            child: const Text('Add'),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Add-CloudStream-repo dialog (TV variant of phone's _CsAddRepoDialog)
// ---------------------------------------------------------------------------

class _TvCsAddRepoDialog extends StatefulWidget {
  const _TvCsAddRepoDialog();

  @override
  State<_TvCsAddRepoDialog> createState() => _TvCsAddRepoDialogState();
}

class _TvCsAddRepoDialogState extends State<_TvCsAddRepoDialog> {
  final _urlCtrl = TextEditingController();
  // Not auto-focused: the dialog opens with the first RECOMMENDED repo focused
  // so a recommendation is one OK-press away and stays visible (auto-raising the
  // leanback IME would cover it). Focus the field + OK to type a custom URL.
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
      title: Text('Add CS repo', style: AppText.headline),
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
                labelText: 'Repo URL',
                hintText: 'https://.../repo.json',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Paste a CloudStream repository URL.',
              style: AppText.caption,
            ),
            // Same recommended repos as the phone dialog, D-pad-focusable.
            TvRecommendedCsRepos(
              onPick: (url) => Navigator.pop(context, url),
            ),
          ],
        ),
      ),
      actions: [
        TvFocusable(scale: 1.0, 
          onTap: () => Navigator.of(context).pop(),
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              'Cancel',
              style: AppText.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ),
        TvFocusable(scale: 1.0, 
          onTap: _submit,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
            ),
            onPressed: _submit,
            child: const Text('Add'),
          ),
        ),
      ],
    );
  }
}
