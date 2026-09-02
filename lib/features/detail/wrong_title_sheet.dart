import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/provider/cf_solve_needed.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/repository/source_actions.dart' as source_actions;
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/zmode/match_store.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart';
import '../../l10n/l10n.dart';
import '../shell/tv_source_picker.dart';
import '../sources/zangetsu_sources_screen.dart';
import 'cubit/detail_cubit.dart';
import 'cubit/source_select_cubit.dart';
import 'cubit/wrong_title_cubit.dart';

/// "Source: AllAnime ▾  Wrong title?" under a metadata title. Tapping the
/// source name opens a picker of installed sources for this title's kind
/// (each keeping its own remembered match); "Wrong title?" corrects the
/// match for whichever source is currently selected.
class MatchLine extends StatefulWidget {
  const MatchLine({
    super.key,
    required this.canonical,
    required this.title,
    this.altTitle,
    this.malId,
  });

  final ZCanonical canonical;
  final String title;
  final String? altTitle;
  final int? malId;

  @override
  State<MatchLine> createState() => _MatchLineState();
}

class _MatchLineState extends State<MatchLine> {
  late final SourceSelectCubit _cubit = SourceSelectCubit(
    store: sl<MatchStore>(),
    matcher: sl<SourceMatcher>(),
    canonical: widget.canonical,
    sources: candidatesForKind(sl<SourceRepository>(), widget.canonical.kind),
    title: widget.title,
    altTitle: widget.altTitle,
    malId: widget.malId,
  );

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  /// Every kind's episode/chapter list is substituted from the matched source
  /// (see `MetadataRepository.detail`) — anime and movie/TV now take their
  /// titles and count from the source too, not just manga/novel. So any
  /// change of selection or correction must re-fetch the Detail screen,
  /// regardless of kind.
  void _refreshAfterMatchChange() =>
      // dropCache: false — the source just switched TO was never in that
      // cache, and clearing it would slow this switch down and every other
      // source with it. Only a deliberate pull-to-refresh wants that.
      context.read<DetailCubit>().refresh(dropCache: false);

  /// Picking a row selects it directly (rather than popping an id for the
  /// caller to act on afterward) so the real store write is a direct
  /// continuation of the tap that triggers it, not of the sheet closing.
  /// Opens the app's own source picker — the same tabbed, searchable sheet the
  /// Home switcher uses, so CloudStream and Aniyomi rows appear here with their
  /// ecosystem labels and repo tags. `onPick` keeps the choice local to this
  /// title: the app's ACTIVE source is deliberately not changed.
  void _pickSource(SourceSelectState state) {
    if (_isTv) {
      showDialog<void>(
        context: context,
        builder: (ctx) => TvSourcePicker(
          currentId: state.selectedId ?? '',
          onPick: (id) async {
            if (id == state.selectedId) return;
            await _cubit.selectSource(id);
            if (mounted) _refreshAfterMatchChange();
          },
        ),
      );
      return;
    }
    SourceSwitcher(
      currentId: state.selectedId ?? '',
      onChanged: (_) {},
      onInstallSources: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const ZangetsuSourcesScreen(openToRepos: true),
        ),
      ),
    ).showPicker(
      context,
      trailingBuilder: (id) => _rowActions(context, id),
      onPick: (id) async {
        if (id == state.selectedId) return;
        await _cubit.selectSource(id);
        if (mounted) _refreshAfterMatchChange();
      },
    );
  }

  // Cloudflare's own brand orange — reused from the Detail-path blocked
  // state (_DetailCloudflareBlocked in detail_screen.dart) so a flagged row
  // reads as the same kind of "attention needed" everywhere it appears.
  static const Color _cfOrange = Color(0xFFF48120);

  Widget _cfSolveButton(
    BuildContext context,
    String id, {
    required bool compact,
  }) {
    final flaggedUrl = CfSolveNeeded.urlFor(id);
    final solveTarget = flaggedUrl ?? sl<SourceRepository>().baseUrlFor(id);
    final showSolve = solveTarget.isNotEmpty;
    if (!showSolve) return const SizedBox.shrink();

    final isJs = !id.startsWith('ani:') &&
        !id.startsWith('mihon:') &&
        !id.startsWith('cs:') &&
        !id.startsWith('lnr:');

    Future<void> solve() async {
      final target =
          await sl<SourceRepository>().cfSolveTargetFor(id) ?? solveTarget;
      if (target.isEmpty) return;
      if (isJs) {
        await sl<ProviderManager>().solveCloudflareForHost(
          Uri.parse(target).host,
          target,
        );
      } else {
        await MihonExtensionService.solveCloudflare(target);
      }
      if (!mounted) return;
      await _cubit.load();
      if (mounted) _refreshAfterMatchChange();
    }

    if (_isTv) {
      return TvFocusable(
        key: ValueKey('tv-source-cf-$id'),
        variant: TvFocusVariant.pill,
        scale: 1.0,
        semanticLabel: context.l10n.solveCloudflare,
        onTap: solve,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
          child: Icon(
            Icons.shield_rounded,
            size: 20,
            color: flaggedUrl == null ? AppColors.textSecondary : _cfOrange,
          ),
        ),
      );
    }

    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: context.l10n.solveCloudflare,
      icon: flaggedUrl == null
          ? const Icon(Icons.shield_rounded, size: 18)
          : const Badge(
              backgroundColor: _cfOrange,
              smallSize: 8,
              child: Icon(Icons.shield_rounded, size: 18),
            ),
      color: flaggedUrl == null ? AppColors.textSecondary : _cfOrange,
      onPressed: solve,
    );
  }

  Widget _settingsButton(BuildContext context, String id, {required bool compact}) {
    return FutureBuilder<bool>(
      future: source_actions.hasSourceSettings(id),
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        void open() => source_actions.openSourceSettings(
          context,
          id,
          sl<SourceRepository>().displayName(id),
        );
        if (_isTv) {
          return TvFocusable(
            key: ValueKey('tv-source-settings-$id'),
            variant: TvFocusVariant.pill,
            scale: 1.0,
            semanticLabel: context.l10n.sourceSettings,
            onTap: open,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
              child: const Icon(
                Icons.tune_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ),
          );
        }
        return IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: context.l10n.sourceSettings,
          icon: const Icon(Icons.tune_rounded, size: 18),
          color: AppColors.textSecondary,
          onPressed: open,
        );
      },
    );
  }

  /// Per-source controls on a picker row: solve Cloudflare, and open that
  /// source's own settings. Each is shown only when it will actually do
  /// something, and neither changes the selection — tapping the row body does.
  ///
  /// The solve action is offered wherever there is a site to solve AGAINST,
  /// not only where a challenge has already been seen. [CfSolveNeeded] is the
  /// record of one, but it lives in memory and is only written while a search
  /// sweep runs — so gating visibility on it hid the action on a fresh launch
  /// for sources that plainly need it (AnimePahe). The flag instead drives
  /// the shield's PROMINENCE, below.
  Widget _rowActions(
    BuildContext context,
    String id, {
    bool compact = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _cfSolveButton(context, id, compact: compact),
        _settingsButton(context, id, compact: compact),
      ],
    );
  }

  Future<void> _fix(String sourceId) async {
    final kind = widget.canonical.kind;
    final before = sl<SourceMatcher>().selectedFor(kind);
    final picked = await showWrongTitleSheet(
      context,
      canonical: widget.canonical,
      title: widget.title,
      sourceId: sourceId,
    );
    if (!mounted) return;
    if (picked == null) {
      // Closed without pinning — but the sheet can change the SOURCE on its
      // own, so a stale row here would name the source the user just left.
      if (sl<SourceMatcher>().selectedFor(kind) != before) {
        await _cubit.load();
        if (mounted) _refreshAfterMatchChange();
      }
      return;
    }
    _cubit.applyPinned(picked);
    _refreshAfterMatchChange();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(context.l10n.matchSaved(
        sl<SourceRepository>().displayName(picked.sourceId)))));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final liveSources =
        candidatesForKind(sl<SourceRepository>(), widget.canonical.kind);
    _cubit.syncSources(liveSources);
    // Metadata detail is browsable without streaming extensions; matching
    // happens at Play / download / an explicit source pick.
    if (liveSources.isEmpty) return const SizedBox.shrink();
    return BlocProvider.value(
      value: _cubit,
      child: BlocBuilder<SourceSelectCubit, SourceSelectState>(
        builder: (context, state) {
          if (state.loading && state.selectedId == null) {
            // Hold the row's place. The Detail screen now paints before the
            // source is resolved, so an empty box here left a hole between
            // Download and the synopsis for the whole sweep — which read as
            // "this title has no source selector" rather than "still looking".
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Container(
                height: 52,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 14),
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Container(
                  width: 120,
                  height: 14,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
              ),
            );
          }
          // Candidates exist and the resolve finished, but nothing genuinely
          // matched anywhere and nothing has been picked by hand yet — the
          // row still opens the picker (there IS something to choose from),
          // it just has no source to name yet and nothing for "Wrong title?"
          // to correct until one is picked.
          final selectedId = state.selectedId;
          // Just the name inside the pill — the shape already reads as a
          // control, so a "Source:" prefix only crowds it.
          final label = selectedId == null
              ? l10n.sourceFallback
              : sl<SourceRepository>().displayName(selectedId);
          // Sized and filled like _DownloadButton directly above, so Play,
          // Download and Source read as one stack. The row body opens the
          // picker; the trailing icons act on the SELECTED source and are
          // outside that InkWell so they never double as a row tap.
          final edge = _isTv
              ? const EdgeInsets.only(top: 10)
              : const EdgeInsets.fromLTRB(16, 10, 16, 0);
          final sourceRow = Row(
            children: [
              Flexible(
                child: Text(
                  label,
                  style: AppText.button.copyWith(
                    color: selectedId == null
                        ? AppColors.textTertiary
                        : AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ],
          );
          if (_isTv) {
            return Padding(
              padding: edge,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TvFocusable(
                    key: const ValueKey('tv-detail-source'),
                    variant: TvFocusVariant.pill,
                    onTap: () => _pickSource(state),
                    semanticLabel: label,
                    child: ExcludeSemantics(
                      child: Container(
                        height: 52,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: AppColors.surface2,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: sourceRow,
                      ),
                    ),
                  ),
                  if (selectedId != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _rowActions(context, selectedId, compact: true),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: state.loading
                              ? const SizedBox.shrink()
                              : !state.resolved
                              ? const SizedBox.shrink()
                              : Text(
                                  state.match?.showTitle.isNotEmpty == true
                                      ? state.match!.showTitle
                                      : l10n.noEpisodesAvailableFromThisSource,
                                  style: AppText.caption.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                        TvFocusable(
                          key: const ValueKey('tv-detail-wrong-title'),
                          variant: TvFocusVariant.pill,
                          scale: 1.0,
                          onTap: () => _fix(selectedId),
                          semanticLabel: l10n.wrongTitle,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            child: Text(
                              l10n.wrongTitle,
                              style: AppText.caption.copyWith(
                                color: AppColors.accent,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            );
          }
          return Padding(
            padding: edge,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Material(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    height: 52,
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () => _pickSource(state),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 14),
                              child: sourceRow,
                            ),
                          ),
                        ),
                        if (selectedId != null) _rowActions(context, selectedId),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
                if (selectedId != null)
                  Row(
                    children: [
                      // What the source actually matched, beside the button
                      // that corrects it. Naming only the SOURCE hid the case
                      // this whole control exists for: a confident match on
                      // the wrong show looks identical to a right one — same
                      // source name, a full episode list — until you play it
                      // and get someone else's episodes. Showing the title
                      // makes a bad match visible without opening anything.
                      //
                      // Silent while still resolving: the screen paints before
                      // the match lands, and an unguarded line would claim
                      // "nothing here" for every title during that window.
                      Expanded(
                        child: state.loading
                            ? const SizedBox.shrink()
                            : !state.resolved
                            ? const SizedBox.shrink()
                            : Text(
                                state.match?.showTitle.isNotEmpty == true
                                    ? state.match!.showTitle
                                    : l10n.noEpisodesAvailableFromThisSource,
                                style: AppText.caption.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                      InkWell(
                        onTap: () => _fix(selectedId),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 8,
                          ),
                          child: Text(
                            l10n.wrongTitle,
                            style: AppText.caption
                                .copyWith(color: AppColors.accent),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Pick a result, correcting the match for exactly [sourceId]. Returns the
/// pinned match.
Future<SourceMatch?> showWrongTitleSheet(
  BuildContext context, {
  required ZCanonical canonical,
  required String title,
  required String sourceId,
}) {
  final body = _WrongTitleBody(
    canonical: canonical,
    initialQuery: title,
    sourceId: sourceId,
  );
  if (sl.isRegistered<AppMode>() && sl<AppMode>().isTv) {
    return showDialog<SourceMatch>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
        child: SizedBox(
          width: 640,
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: body,
        ),
      ),
    );
  }
  return showModalBottomSheet<SourceMatch>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => body,
  );
}

class _WrongTitleBody extends StatelessWidget {
  const _WrongTitleBody({
    required this.canonical,
    required this.initialQuery,
    required this.sourceId,
  });
  final ZCanonical canonical;
  final String initialQuery;
  final String sourceId;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => WrongTitleCubit(
        sources: sl<SourceRepository>(),
        matcher: sl<SourceMatcher>(),
        canonical: canonical,
        sourceId: sourceId,
      )..search(initialQuery),
      child: _WrongTitleView(initialQuery: initialQuery),
    );
  }
}

class _WrongTitleView extends StatefulWidget {
  const _WrongTitleView({required this.initialQuery});
  final String initialQuery;
  @override
  State<_WrongTitleView> createState() => _WrongTitleViewState();
}

class _WrongTitleViewState extends State<_WrongTitleView> {
  late final _ctrl = TextEditingController(text: widget.initialQuery);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _pickWrongTitleSource(WrongTitleCubit cubit) {
    if (sl.isRegistered<AppMode>() && sl<AppMode>().isTv) {
      showDialog<void>(
        context: context,
        builder: (ctx) => TvSourcePicker(
          currentId: cubit.sourceId,
          onPick: cubit.setSource,
        ),
      );
      return;
    }
    SourceSwitcher(
      currentId: cubit.sourceId,
      onChanged: (_) {},
      onInstallSources: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const ZangetsuSourcesScreen(openToRepos: true),
        ),
      ),
    ).showPicker(
      context,
      onPick: cubit.setSource,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<WrongTitleCubit>();
    final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
    final sourceLabel = l10n.sourceLabel(
      sl<SourceRepository>().displayName(cubit.sourceId),
    );
    final sourceChip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          sourceLabel,
          style: AppText.caption.copyWith(color: AppColors.textSecondary),
        ),
        Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 16,
          color: AppColors.textSecondary,
        ),
      ],
    );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: isTv ? null : MediaQuery.sizeOf(context).height * 0.75,
          child: BlocBuilder<WrongTitleCubit, WrongTitleState>(
            builder: (context, state) => Column(
              children: [
                const SizedBox(height: 12),
                Text(l10n.pickTheRightTitle, style: AppText.headline),
                const SizedBox(height: 2),
                if (isTv)
                  TvFocusable(
                    variant: TvFocusVariant.pill,
                    scale: 1.0,
                    onTap: () => _pickWrongTitleSource(cubit),
                    semanticLabel: sourceLabel,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: sourceChip,
                    ),
                  )
                else
                  InkWell(
                    onTap: () => _pickWrongTitleSource(cubit),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: sourceChip,
                    ),
                  ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: TextField(
                    controller: _ctrl,
                    onSubmitted: cubit.search,
                    textInputAction: TextInputAction.search,
                    style: AppText.body,
                    decoration: InputDecoration(
                      hintText: l10n.searchThisSource,
                      prefixIcon: const Icon(Icons.search_rounded),
                    ),
                  ),
                ),
                if (state.loading) ...[
                  const LinearProgressIndicator(minHeight: 2),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      // Which query is running, not just that one is: a source
                      // can take seconds, and after switching source it is the
                      // only thing saying what is being re-searched.
                      child: Text(
                        '${l10n.searching}: ${state.query}',
                        style: AppText.caption
                            .copyWith(color: AppColors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                Expanded(
                  child: ListView.builder(
                    itemCount: state.results.length,
                    itemBuilder: (_, i) {
                      final r = state.results[i];
                      return ListTile(
                        leading: r.cover == null
                            ? null
                            : Image.network(r.cover!, width: 40, fit: BoxFit.cover),
                        title: Text(r.title, style: AppText.body),
                        subtitle: r.englishTitle == null
                            ? null
                            : Text(r.englishTitle!, style: AppText.caption),
                        onTap: () async {
                          final m = await cubit.choose(r);
                          if (context.mounted) Navigator.of(context).pop(m);
                        },
                      );
                    },
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
