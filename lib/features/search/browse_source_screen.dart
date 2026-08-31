import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/di/injector.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/models/home_section.dart';
import '../../core/models/media_item.dart';
import '../../core/repository/source_actions.dart' as source_actions;
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/content_row.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/source_switcher.dart' show sourceTypeOf;
import '../../l10n/l10n.dart';
import '../detail/detail_screen.dart';
import '../home/see_all_screen.dart';
import 'bloc/search_state.dart' show ecosystemOf;
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
        create: (_) => BrowseSourceCubit(
          repo: sl<SourceRepository>(),
          sourceId: sourceId,
        )..load(),
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
  late final String _displayName =
      sl<SourceRepository>().displayName(widget.sourceId);
  late final String _ecosystem = ecosystemOf(widget.sourceId).label;
  late final String _kind = sourceTypeOf(widget.sourceId).name;
  late final String? _language =
      sl<SourceRepository>().languageFor(widget.sourceId);

  // Overflow-menu availability. [_baseUrl] is sync (a plain field lookup),
  // so Cloudflare/open-in-browser gate immediately; source-settings needs a
  // platform-channel round trip, so it stays a Future the menu awaits.
  late final String _baseUrl = sl<SourceRepository>().baseUrlFor(widget.sourceId);
  bool get _canSolveCloudflare => _baseUrl.isNotEmpty;
  bool get _canOpenInBrowser => _baseUrl.isNotEmpty;
  late final Future<bool> _hasSettings =
      source_actions.hasSourceSettings(widget.sourceId);
  late final bool _canResetData =
      source_actions.canResetSourceData(widget.sourceId);

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
                : (page) => sl<SourceRepository>().browseMore(section.more!, page),
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

  /// Open the source's own site in the system browser — same launcher +
  /// failure snackbar as Detail's Web button, just pointed at the source's
  /// base url instead of one title's url (this screen has no item in hand).
  Future<void> _openInBrowser() async {
    final ok =
        await launchUrl(Uri.parse(_baseUrl), mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(context.l10n.couldNotOpenSourceSite)));
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
            child: Text(ctx.l10n.reset, style: TextStyle(color: AppColors.accent)),
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
                onSubmitted: (q) =>
                    context.read<BrowseSourceCubit>().search(q),
              )
            : Text(widget.title, style: AppText.headline),
        actions: [
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
            onSolveCloudflare: () => MihonExtensionService.solveCloudflare(_baseUrl),
            onOpenInBrowser: _openInBrowser,
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
                      itemWidth: 140,
                      itemHeight: 236,
                      itemCount: items.length,
                      onSeeAll: () => _openSeeAll(context, section),
                      itemBuilder: (c, j) => PosterCard(
                        title: items[j].title,
                        imageUrl: items[j].cover,
                        headers: items[j].coverHeaders,
                        cellWidth: 140,
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
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.62,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: results.length,
      itemBuilder: (_, i) {
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
    required this.onResetData,
  });

  final Future<bool> hasSettings;
  final bool canSolveCloudflare;
  final bool canOpenInBrowser;
  final bool canResetData;
  final VoidCallback onSettings;
  final VoidCallback onSolveCloudflare;
  final VoidCallback onOpenInBrowser;
  final VoidCallback onResetData;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: hasSettings,
      builder: (context, snapshot) {
        final settingsReady = snapshot.data ?? false;
        if (!settingsReady &&
            !canSolveCloudflare &&
            !canOpenInBrowser &&
            !canResetData) {
          return const SizedBox.shrink();
        }
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
            style: AppText.headline.copyWith(fontSize: 21, fontWeight: FontWeight.w800),
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
