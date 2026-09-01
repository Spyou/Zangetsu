import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ui/app_toast.dart';
import '../../core/di/injector.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/repository/source_actions.dart' as source_actions;
import '../../core/repository/source_domain_overrides.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/source_switcher.dart' show sourceTypeOf;
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../home/see_all_screen.dart';
import '../../core/aniyomi/aniyomi_filters.dart';
import '../../core/mihon/mihon_filters.dart';
import '../aniyomi/aniyomi_filter_sheet.dart';
import '../mihon/mihon_filter_sheet.dart';
import 'bloc/search_state.dart' show SearchEcosystem, ecosystemOf;
import 'cubit/browse_source_cubit.dart';

/// One source's catalogue — today's Home, pinned to a chosen source.
///
/// Browsing a source is NOT selecting it: nothing here touches
/// ActiveSourceCubit, so the app's active source survives the visit.
class BrowseSourceScreen extends StatelessWidget {
  const BrowseSourceScreen({
    super.key,
    required this.sourceId,
    required this.title,
  });

  final String sourceId;
  final String title;

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) =>
        BrowseSourceCubit(repo: sl<SourceRepository>(), sourceId: sourceId)
          ..load(),
    child: _BrowseSourceView(sourceId: sourceId, title: title),
  );
}

class _BrowseSourceView extends StatefulWidget {
  const _BrowseSourceView({required this.sourceId, required this.title});

  final String sourceId;
  final String title;

  @override
  State<_BrowseSourceView> createState() => _BrowseSourceViewState();
}

class _BrowseSourceViewState extends State<_BrowseSourceView> {
  // Search is view state, not screen state — whether the AppBar shows the
  // title or the field never needs to survive a rebuild of anything else.
  bool _searching = false;
  late final _controller = TextEditingController();
  final _focusNode = FocusNode();

  // Identity header content — computed once, it never changes for the life
  // of this screen. [_displayName] is the source's clean name (unlike
  // [widget.title], which can carry an ecosystem prefix baked into the
  // picker's label). [_ecosystem]/[_kind] reuse the app's existing id-prefix
  // resolvers (same ones the Search ecosystem tabs and the source picker's
  // mode filter use) rather than inventing a new classification; [_language]
  // is null whenever the ecosystem doesn't report one (CloudStream/plain JS/
  // LNReader today) — omitted rather than shown as "unknown".
  late final String _displayName = sl<SourceRepository>().displayName(
    widget.sourceId,
  );
  late final SearchEcosystem _eco = ecosystemOf(widget.sourceId);
  late final String _ecosystem = _eco.label;

  /// Only the extension ecosystems publish a filter schema. CloudStream and
  /// Zangetsu sources have no such concept, so they get no filter button
  /// rather than one that opens an empty sheet.
  bool get _canFilter =>
      _eco == SearchEcosystem.aniyomi || _eco == SearchEcosystem.mihon;
  late final String _kind = sourceTypeOf(widget.sourceId).name;
  late final String? _language = sl<SourceRepository>().languageFor(
    widget.sourceId,
  );

  // Overflow-menu availability. [_baseUrl] is sync (a plain field lookup),
  // so Cloudflare/open-in-browser gate immediately; source-settings needs a
  // platform-channel round trip, so it stays a Future the menu awaits.
  // Not `late final`: setting a domain override changes what this answers,
  // and the menu has to reflect that without reopening the screen.
  String get _baseUrl => sl<SourceRepository>().baseUrlFor(widget.sourceId);
  bool get _canSolveCloudflare => _baseUrl.isNotEmpty;
  bool get _canOpenInBrowser => _baseUrl.isNotEmpty;
  late final Future<bool> _hasSettings = source_actions.hasSourceSettings(
    widget.sourceId,
  );
  late final bool _canResetData = source_actions.canResetSourceData(
    widget.sourceId,
  );

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _openDetail(BuildContext context, MediaItem item) =>
      Navigator.of(context).push(DetailScreen.route(item));

  void _openSeeAll(BuildContext context, HomeSection section) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SeeAllScreen(
            title: section.title,
            items: section.items,
            onTap: (i) => _openDetail(context, i),
            onLoadMore: section.more == null
                ? null
                : (page) =>
                      sl<SourceRepository>().browseMore(section.more!, page),
          ),
        ),
      );

  void _startSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _stopSearch(BuildContext context) {
    _controller.clear();
    context.read<BrowseSourceCubit>().clearSearch();
    setState(() => _searching = false);
  }

  /// Resolves the solve target fresh (see [SourceRepository.cfSolveTargetFor])
  /// right before opening the solve WebView, instead of the cached [_baseUrl]
  /// — a CloudStream plugin can rewrite its own `mainUrl` after resolving its
  /// live domain, so the value captured when this screen was built can be
  /// stale by the time the user taps this. A no-op (not a broken open) when
  /// nothing usable can be found — [_canSolveCloudflare] already keeps the
  /// menu entry hidden in the ordinary case there's truly nothing at all.
  Future<void> _solveCloudflare() async {
    final target = await sl<SourceRepository>().cfSolveTargetFor(
      widget.sourceId,
    );
    if (target == null || target.isEmpty) return;
    await MihonExtensionService.solveCloudflare(target);
  }

  /// Let the user point this source's site actions at a domain of their own.
  ///
  /// An extension that has stopped being updated keeps reporting a domain
  /// that has since died, and nothing app-side can derive the live one from
  /// it. This does NOT redirect the extension's own fetching (see
  /// [SourceDomainOverrides]) — it fixes the two things the app does own:
  /// "open in browser" and the Cloudflare solve.
  Future<void> _editDomain() async {
    final store = sl<SourceDomainOverrides>();
    final controller = TextEditingController(
      text: store.get(widget.sourceId) ?? _baseUrl,
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.sourceDomain),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: dialogContext.l10n.sourceDomainHint,
          ),
          onSubmitted: (_) => Navigator.of(dialogContext).pop(true),
        ),
        actions: [
          // Reset clears the override; it does not blank the site, it hands
          // the source back to whatever domain the extension reports.
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.l10n.reset),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(null),
            child: Text(dialogContext.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (saved == null) return; // cancelled
    if (saved) {
      await store.set(widget.sourceId, controller.text);
    } else {
      await store.clear(widget.sourceId);
    }
    if (mounted) setState(() {}); // the menu's gating reads _baseUrl
  }

  /// Open the source's own site in the system browser — same launcher +
  /// failure snackbar as Detail's Web button, just pointed at the source's
  /// base url instead of one title's url (this screen has no item in hand).
  Future<void> _openInBrowser() async {
    final ok = await launchUrl(
      Uri.parse(_baseUrl),
      mode: LaunchMode.externalApplication,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(context.l10n.couldNotOpenSourceSite)),
        );
    }
  }

  /// Confirms, then clears THIS source's own saved state (settings + its
  /// site's cookies) via [source_actions.resetSourceData]. Destructive to
  /// that source alone — never touches the active source, another source,
  /// or anything app-side (My List, history, downloads).
  Future<void> _confirmResetData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(ctx.l10n.reset, style: AppText.title),
        content: Text(
          ctx.l10n.resetSourceDataConfirm(_displayName),
          style: AppText.body,
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              ctx.l10n.reset,
              style: TextStyle(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await source_actions.resetSourceData(widget.sourceId);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(context.l10n.done)));
  }

  /// Opens the source's own filter sheet and browses with the result.
  ///
  /// Split per ecosystem rather than unified behind a common type: the two
  /// filter models are separate by design, and the same split is what the
  /// search screen does.
  Future<void> _openFilters(String stored) => _eco == SearchEcosystem.mihon
      ? _openMihonFilters(stored)
      : _openAniFilters(stored);

  /// [stored] is the selection already applied, so reopening the sheet shows
  /// the last choice instead of resetting to defaults.
  Future<void> _openAniFilters(String stored) async {
    final filters = stored.isNotEmpty
        ? AniyomiFilters.parse(stored)
        // Source-specific filter schema — not a CatalogueRepository call.
        : await sl<SourceRepository>().aniFilters(widget.sourceId);
    if (!mounted || !_warnIfEmpty(filters)) return;
    final result = await showAniyomiFilterSheet(context, filters);
    if (result == null || !mounted) return;
    await context.read<BrowseSourceCubit>().applyFilters(
      AniyomiFilters.toSelectionJson(result),
    );
  }

  /// Mihon twin of [_openAniFilters].
  Future<void> _openMihonFilters(String stored) async {
    final filters = stored.isNotEmpty
        ? MihonFilters.parse(stored)
        : await sl<SourceRepository>().mihonFilters(widget.sourceId);
    if (!mounted || !_warnIfEmpty(filters)) return;
    final result = await showMihonFilterSheet(context, filters);
    if (result == null || !mounted) return;
    await context.read<BrowseSourceCubit>().applyFilters(
      MihonFilters.toSelectionJson(result),
    );
  }

  /// False when there is nothing to show, having said so.
  bool _warnIfEmpty(List<Object?> filters) {
    if (filters.isNotEmpty) return true;
    showAppToast(context, context.l10n.thisSourceHasNoFilters);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: _searching
            ? TextField(
                controller: _controller,
                focusNode: _focusNode,
                autofocus: true,
                textInputAction: TextInputAction.search,
                style: AppText.body.copyWith(color: AppColors.textPrimary),
                cursorColor: AppColors.accent,
                decoration: InputDecoration(
                  hintText: context.l10n.search2,
                  hintStyle: AppText.body,
                  border: InputBorder.none,
                ),
                onSubmitted: (q) => context.read<BrowseSourceCubit>().search(q),
              )
            : Text(widget.title, style: AppText.headline),
        actions: [
          if (_canFilter && !_searching)
            BlocBuilder<BrowseSourceCubit, BrowseSourceState>(
              buildWhen: (a, b) => a.filtersJson != b.filtersJson,
              builder: (context, state) {
                final on = state.filtersJson.isNotEmpty;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        on
                            ? Icons.filter_list_rounded
                            : Icons.filter_list_outlined,
                        color: on ? AppColors.accent : null,
                      ),
                      tooltip: context.l10n.sourceFilters,
                      onPressed: () => _openFilters(state.filtersJson),
                    ),
                    // The sheet's Reset only restores default VALUES, and those
                    // still serialise to a selection, so it can't be the way
                    // back to the unfiltered catalogue. Without this there
                    // isn't one.
                    if (on)
                      IconButton(
                        icon: const Icon(Icons.filter_list_off_rounded),
                        tooltip: context.l10n.clearFilters,
                        onPressed: () =>
                            context.read<BrowseSourceCubit>().applyFilters(''),
                      ),
                  ],
                );
              },
            ),
          IconButton(
            icon: Icon(_searching ? Icons.close_rounded : Icons.search),
            tooltip: _searching
                ? context.l10n.clear
                : context.l10n.searchThisSource,
            onPressed: _searching ? () => _stopSearch(context) : _startSearch,
          ),
          _SourceOverflowMenu(
            hasSettings: _hasSettings,
            canSolveCloudflare: _canSolveCloudflare,
            canOpenInBrowser: _canOpenInBrowser,
            canResetData: _canResetData,
            onSettings: () => source_actions.openSourceSettings(
              context,
              widget.sourceId,
              _displayName,
            ),
            onSolveCloudflare: _solveCloudflare,
            onOpenInBrowser: _openInBrowser,
            onEditDomain: _editDomain,
            onResetData: _confirmResetData,
          ),
        ],
      ),
      body: Column(
        children: [
          // Above the rows, not the search field — matches the mockup, and
          // keeps the search AppBar exactly as it was.
          if (!_searching)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: _SourceIdentityHeader(
                name: _displayName,
                ecosystem: _ecosystem,
                language: _language,
                kind: _kind,
              ),
            ),
          Expanded(
            child: BlocBuilder<BrowseSourceCubit, BrowseSourceState>(
              builder: (context, state) {
                if (state.isSearchActive) {
                  return _searchBody(context, state);
                }
                if (state.loading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (state.failed || state.sections.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        state.failed
                            ? context.l10n.somethingWentWrong
                            : context.l10n.noTitlesInThisList,
                        style: AppText.caption,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: state.sections.length,
                  itemBuilder: (_, i) {
                    final section = state.sections[i];
                    final items = section.items;
                    return ContentRow(
                      title: section.title,
                      itemWidth: 116,
                      itemHeight: 216,
                      itemCount: items.length,
                      onSeeAll: () => _openSeeAll(context, section),
                      itemBuilder: (c, j) => PosterCard(
                        title: items[j].title,
                        imageUrl: items[j].cover,
                        headers: items[j].coverHeaders,
                        cellWidth: 116,
                        qualityBadge: items[j].quality,
                        dubBadge: items[j].dubBadge,
                        onTap: () => _openDetail(context, items[j]),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Search spinner / failure / empty / results grid — mirrors the
  /// single-source flat grid in `search_screen.dart`'s `_resultsGrid`.
  Widget _searchBody(BuildContext context, BrowseSourceState state) {
    if (state.searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.searchFailed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            context.l10n.somethingWentWrong,
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final results = state.searchResults ?? const [];
    if (results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            context.l10n.noTitlesInThisList,
            style: AppText.caption,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final cubit = context.read<BrowseSourceCubit>();
    return NotificationListener<ScrollNotification>(
      // Keep paging as you scroll, the way the extensions' own browse does.
      // Fires a screen early so the next page is usually there before you
      // reach the bottom; the cubit ignores the call while one is in flight
      // or once the source stops returning anything new.
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - n.metrics.viewportDimension) {
          cubit.loadMore();
        }
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: posterGridAspect(context),
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
        ),
        // One trailing cell for the spinner while the next page is coming.
        itemCount: results.length + (state.loadingMore ? 1 : 0),
        itemBuilder: (_, i) {
          if (i >= results.length) {
            return Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.accent,
                ),
              ),
            );
          }
          final item = results[i];
          return PosterCard(
            title: item.title,
            imageUrl: item.cover,
            headers: item.coverHeaders,
            qualityBadge: item.quality,
            dubBadge: item.dubBadge,
            onTap: () => _openDetail(context, item),
          );
        },
      ),
    );
  }
}

/// The search icon's neighbour: source settings, solve Cloudflare, open in
/// browser, reset source data — each entry present only when it will
/// actually do something, no overflow button at all when none apply. No new
/// plumbing: settings reuses [source_actions.hasSourceSettings]/
/// [source_actions.openSourceSettings] (same check the wrong-title sheet's
/// per-row actions use), Cloudflare reuses [MihonExtensionService.solveCloudflare],
/// the browser opener mirrors Detail's Web button, and reset reuses
/// [source_actions.canResetSourceData]/[source_actions.resetSourceData].
/// Never touches the active source — every callback is the caller's, and
/// none of them call ActiveSourceCubit.
class _SourceOverflowMenu extends StatelessWidget {
  const _SourceOverflowMenu({
    required this.hasSettings,
    required this.canSolveCloudflare,
    required this.canOpenInBrowser,
    required this.canResetData,
    required this.onSettings,
    required this.onSolveCloudflare,
    required this.onOpenInBrowser,
    required this.onEditDomain,
    required this.onResetData,
  });

  final Future<bool> hasSettings;
  final bool canSolveCloudflare;
  final bool canOpenInBrowser;
  final bool canResetData;
  final VoidCallback onSettings;
  final VoidCallback onSolveCloudflare;
  final VoidCallback onOpenInBrowser;
  final VoidCallback onEditDomain;
  final VoidCallback onResetData;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: hasSettings,
      builder: (context, snapshot) {
        final settingsReady = snapshot.data ?? false;
        return PopupMenuButton<VoidCallback>(
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (action) => action(),
          itemBuilder: (context) => [
            if (settingsReady)
              PopupMenuItem<VoidCallback>(
                value: onSettings,
                child: Text(context.l10n.sourceSettings),
              ),
            if (canSolveCloudflare)
              PopupMenuItem<VoidCallback>(
                value: onSolveCloudflare,
                child: Text(context.l10n.solveCloudflare),
              ),
            if (canOpenInBrowser)
              PopupMenuItem<VoidCallback>(
                value: onOpenInBrowser,
                child: Text(context.l10n.openSourceSite),
              ),
            // Always offered: it exists precisely for the case where the
            // reported domain is wrong, so it cannot gate on that domain.
            PopupMenuItem<VoidCallback>(
              value: onEditDomain,
              child: Text(context.l10n.sourceDomain),
            ),
            if (canResetData)
              PopupMenuItem<VoidCallback>(
                value: onResetData,
                child: Text(context.l10n.reset),
              ),
          ],
        );
      },
    );
  }
}

/// Rounded initial tile + name + small ecosystem/language/kind tag pills,
/// above the rows — so a source's own catalogue reads as its own place
/// rather than a bare list under an AppBar title.
class _SourceIdentityHeader extends StatelessWidget {
  const _SourceIdentityHeader({
    required this.name,
    required this.ecosystem,
    required this.language,
    required this.kind,
  });

  final String name;
  final String ecosystem;
  final String? language;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 52,
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.surface2,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            initial,
            style: AppText.headline.copyWith(
              fontSize: 21,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                name,
                style: AppText.body.copyWith(
                  color: AppColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _IdentityTag(ecosystem),
                  if (language != null && language!.isNotEmpty)
                    _IdentityTag(language!),
                  _IdentityTag(kind),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One small uppercase pill under the identity block ("MIHON", "EN",
/// "MANGA") — never printed for data we don't actually have (see the callers
/// above), just omitted.
class _IdentityTag extends StatelessWidget {
  const _IdentityTag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text.toUpperCase(),
        style: AppText.caption.copyWith(
          color: AppColors.textSecondary,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}
