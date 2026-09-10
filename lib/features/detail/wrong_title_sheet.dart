import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/app_toast.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/models/media_item.dart';
import '../../core/provider/cf_solve_needed.dart';
import '../../core/provider/provider_manager.dart';
import '../../core/repository/source_actions.dart' as source_actions;
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/poster_card.dart';
import '../../core/ui/reveal_item.dart';
import '../../core/ui/states.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/theme/app_text.dart';
import '../../core/zmode/match_store.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart';
import '../../l10n/l10n.dart';
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
  )..load();

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

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
      // Auto Resolve sits above the sources rather than among them, because
      // it is not one: it is the absence of a pinned choice, which lets the
      // resolver sweep every source at play time. Picking a source here pins
      // that title to it; this is how you undo that.
      autoSelected: state.auto,
      onAutoResolve: () async {
        await _cubit.selectAuto();
        if (mounted) _refreshAfterMatchChange();
      },
      onPick: (id) async {
        if (!state.auto && id == state.selectedId) return;
        await _cubit.selectSource(id);
        if (mounted) _refreshAfterMatchChange();
      },
    );
  }

  // Cloudflare's own brand orange — reused from the Detail-path blocked
  // state (_DetailCloudflareBlocked in detail_screen.dart) so a flagged row
  // reads as the same kind of "attention needed" everywhere it appears.
  static const Color _cfOrange = Color(0xFFF48120);

  /// Per-source controls on a picker row, behind a single overflow: solve
  /// Cloudflare, sign in to the source's site, and open that source's own
  /// settings. Each entry is offered only when it will actually do something,
  /// and none of them changes the selection — tapping the row body does.
  ///
  /// One button rather than three icons: these are rare, per-source actions
  /// (you sign in to a source about twice, ever) and the row has a name to
  /// show. Same shape the browse screen's toolbar already uses.
  ///
  /// The solve action is offered wherever there is a site to solve AGAINST,
  /// not only where a challenge has already been seen. [CfSolveNeeded] is the
  /// record of one, but it lives in memory and is only written while a search
  /// sweep runs — so gating visibility on it hid the action on a fresh launch
  /// for sources that plainly need it (AnimePahe). The flag instead decides
  /// WHERE the action sits: a flagged source keeps its shield on the row, one
  /// tap from a solve, while an unflagged one folds it into the overflow with
  /// everything else. Solving is the one action here you may do repeatedly,
  /// and only a flagged source is about to need it.
  Widget _rowActions(BuildContext sheetContext, String id) {
    final flaggedUrl = CfSolveNeeded.urlFor(id);
    // Empty for a plain JS provider with no declared site — which doubles as
    // the honest signal that there is nothing to solve, so it gets no entry.
    final solveTarget = flaggedUrl ?? sl<SourceRepository>().baseUrlFor(id);
    final showSolve = solveTarget.isNotEmpty;
    final showSignIn = source_actions.webViewUrlFor(id) != null;
    // A flagged source shows its shield on the row instead, so the menu
    // must not offer the same solve a second time.
    final flagged = flaggedUrl != null;
    // The native solver owns the Mihon/Aniyomi/CloudStream cookie jars; plain
    // JS providers run on Dio and need ProviderManager's own solve. Same
    // id-prefix routing source_actions.hasSourceSettings uses.
    final isJs =
        !id.startsWith('ani:') &&
        !id.startsWith('mihon:') &&
        !id.startsWith('cs:') &&
        !id.startsWith('lnr:');
    return FutureBuilder<bool>(
      future: source_actions.hasSourceSettings(id),
      builder: (context, snapshot) {
        final showSettings = snapshot.data == true;
        // Solving is in the menu only when the shield isn't already on the row.
        final menuSolve = showSolve && !flagged;
        final hasMenu = menuSolve || showSignIn || showSettings;
        // Nothing to offer — no empty menu to tap into.
        if (!flagged && !hasMenu) return const SizedBox.shrink();
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (flagged)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: sheetContext.l10n.solveCloudflare,
                icon: const Badge(
                  backgroundColor: _cfOrange,
                  smallSize: 8,
                  child: Icon(Icons.shield_rounded, size: 18),
                ),
                color: _cfOrange,
                onPressed: () => _solveCloudflare(id, solveTarget, isJs: isJs),
              ),
            if (hasMenu)
              _overflow(
                sheetContext,
                id,
                solveTarget,
                isJs: isJs,
                showSolve: menuSolve,
                showSignIn: showSignIn,
                showSettings: showSettings,
              ),
          ],
        );
      },
    );
  }

  /// The rare per-source actions, behind one button.
  Widget _overflow(
    BuildContext sheetContext,
    String id,
    String solveTarget, {
    required bool isJs,
    required bool showSolve,
    required bool showSignIn,
    required bool showSettings,
  }) {
    return PopupMenuButton<VoidCallback>(
      tooltip: sheetContext.l10n.more,
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert_rounded, size: 18),
      iconColor: AppColors.textSecondary,
      onSelected: (run) => run(),
      itemBuilder: (_) => [
        if (showSolve)
          PopupMenuItem<VoidCallback>(
            value: () => _solveCloudflare(id, solveTarget, isJs: isJs),
            child: Text(sheetContext.l10n.solveCloudflare),
          ),
        if (showSignIn)
          PopupMenuItem<VoidCallback>(
            value: () => source_actions.openSourceWebView(id),
            child: Text(sheetContext.l10n.signInToSource),
          ),
        if (showSettings)
          PopupMenuItem<VoidCallback>(
            value: () => source_actions.openSourceSettings(
              sheetContext,
              id,
              sl<SourceRepository>().displayName(id),
            ),
            child: Text(sheetContext.l10n.sourceSettings),
          ),
      ],
    );
  }

  /// Runs a Cloudflare solve for [id] and reloads the match, so the user sees
  /// the result instead of having to retry by hand.
  Future<void> _solveCloudflare(
    String id,
    String fallbackTarget, {
    required bool isJs,
  }) async {
    // Resolve the target at TAP time, not render time: a CloudStream plugin
    // rewrites its own mainUrl once it has fetched its live domain list, and
    // a user-set domain override outranks both.
    final target =
        await sl<SourceRepository>().cfSolveTargetFor(id) ?? fallbackTarget;
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

  Future<void> _fix(String sourceId) async {
    final before = sl<SourceMatcher>().sourceForTitle(widget.canonical);
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
      if (sl<SourceMatcher>().sourceForTitle(widget.canonical) != before) {
        await _cubit.load();
        if (mounted) _refreshAfterMatchChange();
      }
      return;
    }
    _cubit.applyPinned(picked);
    _refreshAfterMatchChange();
    showAppToast(
      context,
      context.l10n.matchSaved(
        sl<SourceRepository>().displayName(picked.sourceId),
      ),
    );
  }

  bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  /// Source dropdown and "Wrong title?" are separate D-pad targets on TV.
  /// Phone keeps InkWell.
  Widget _tappable({
    required VoidCallback onTap,
    required Widget child,
    required String semanticLabel,
    Key? key,
    double borderRadius = 8,
  }) {
    if (_isTv) {
      return TvFocusable(
        key: key,
        onTap: onTap,
        variant: TvFocusVariant.float,
        scale: 1.02,
        borderRadius: borderRadius,
        semanticLabel: semanticLabel,
        child: ExcludeSemantics(child: child),
      );
    }
    return InkWell(onTap: onTap, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return BlocProvider.value(
      value: _cubit,
      child: BlocBuilder<SourceSelectCubit, SourceSelectState>(
        builder: (context, state) {
          if (state.sources.isEmpty) {
            return Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Icon(
                    Icons.hub_outlined,
                    size: 15,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(width: 6),
                  // Nothing is INSTALLED — which is not the same as nothing
                  // having the title, and saying the latter blames the show
                  // for the app being empty.
                  Text(l10n.noSourcesInstalled, style: AppText.caption),
                ],
              ),
            );
          }
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
          //
          // Auto Resolve is the primary answer until the user pins a source.
          // A settled candidate (from a prior sweep) may still be known —
          // show it dimmer in parentheses so the pill doesn't read like a
          // manual pick. Hardcoded like the picker's own row
          // (source_switcher.dart) rather than an l10n key, so the two
          // always read the same.
          final autoHint = state.auto && selectedId != null
              ? sl<SourceRepository>().taggedName(selectedId)
              : null;
          final semanticLabel = state.auto
              ? (autoHint == null ? 'Auto Resolve' : 'Auto Resolve ($autoHint)')
              : selectedId == null
              ? l10n.noSourceHasThisYet
              : sl<SourceRepository>().taggedName(selectedId);
          // Sized and filled like _DownloadButton directly above, so Play,
          // Download and Source read as one stack. The row body opens the
          // picker; the trailing icons act on the SELECTED source and are
          // outside that tap target so they never double as a row tap.
          // On TV the full gray dropdown pill is one TvFocusable; "Wrong
          // title?" is a second — D-pad can land on each independently.
          final labelRow = Row(
            children: [
              // Glyph so the pill reads as "this picks your source" on
              // sight — sparkle for Auto Resolve, dns for a pinned pick.
              Icon(
                state.auto ? Icons.auto_awesome_rounded : Icons.dns_rounded,
                size: 16,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  state.auto
                      ? 'Auto Resolve'
                      : selectedId == null
                      ? l10n.noSourceHasThisYet
                      : sl<SourceRepository>().taggedName(selectedId),
                  style: AppText.button.copyWith(
                    // Dimmed only when there is no source to name at all; a
                    // source the user picked reads normally even when it
                    // came up empty — the line below the pill says so
                    // outright.
                    color: !state.auto && selectedId == null
                        ? AppColors.textTertiary
                        : AppColors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Dimmed candidate + chevron hug the trailing edge so the
              // primary label stays left and the hint/arrow stay right.
              if (autoHint != null) ...[
                const SizedBox(width: 8),
                Text(
                  '($autoHint)',
                  style: AppText.button.copyWith(
                    fontSize: (AppText.button.fontSize ?? 14) - 2,
                    color: AppColors.textTertiary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const SizedBox(width: 4),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
            ],
          );
          // Its own side padding, because detail_screen.dart pads each button
          // individually rather than wrapping the Column — this line sits as a
          // plain last child and has to bring its own, or it runs to the edge
          // while Play and Download above it stay inset. TV lays the row out
          // itself and wants the full width.
          return Padding(
            padding: _isTv
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_isTv)
                  Row(
                    children: [
                      Expanded(
                        child: _tappable(
                          key: const ValueKey('tv-match-source'),
                          onTap: () => _pickSource(state),
                          semanticLabel: semanticLabel,
                          child: Material(
                            color: AppColors.surface2,
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              height: 52,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                                child: labelRow,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (selectedId != null) _rowActions(context, selectedId),
                    ],
                  )
                else
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
                                child: labelRow,
                              ),
                            ),
                          ),
                          if (selectedId != null)
                            _rowActions(context, selectedId),
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
                      _tappable(
                        key: const ValueKey('tv-match-wrong-title'),
                        onTap: () => _fix(selectedId),
                        semanticLabel: l10n.wrongTitle,
                        borderRadius: 6,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
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
  return showModalBottomSheet<SourceMatch>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _WrongTitleBody(
      canonical: canonical,
      initialQuery: title,
      sourceId: sourceId,
    ),
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

  /// The result this title is pinned to on the source being searched, so the
  /// poster the user already chose is marked instead of offered again as if
  /// it were new. Read per build rather than held: picking a result rebuilds
  /// this sheet, and the store is the only thing that knows.
  String? _currentUrl(String sourceId) => sl<MatchStore>()
      .get(context.read<WrongTitleCubit>().canonical, sourceId)
      ?.showUrl;

  void _openSourcePicker(WrongTitleCubit cubit) => SourceSwitcher(
    currentId: cubit.sourceId,
    onChanged: (_) {},
    onInstallSources: () => Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ZangetsuSourcesScreen(openToRepos: true),
      ),
    ),
  ).showPicker(context, onPick: (id) => cubit.setSource(id));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<WrongTitleCubit>();
    // Matches the Search screen's grid exactly: 3 up, 12 across, 16 down, and
    // the same aspect helper — so a result here is the same object a search
    // result is, at the same size, with the same press animation.
    final cellWidth = (MediaQuery.sizeOf(context).width - 32 - 24) / 3;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: BlocBuilder<WrongTitleCubit, WrongTitleState>(
            builder: (context, state) {
              final currentUrl = _currentUrl(cubit.sourceId);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 12),
                  // Title left, source right, one line. The source used to sit
                  // centred underneath as grey text with a caret, which read as
                  // a label rather than the button it is.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.whichOneIsIt,
                            style: AppText.headline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 10),
                        _SourcePill(
                          sourceId: cubit.sourceId,
                          onTap: () => _openSourcePicker(cubit),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    // The metadata Search bar, same shape: a fully rounded
                    // surface2 pill with the icon INSIDE it, not an
                    // InputDecoration prefix on a boxed field. This sheet is
                    // reached from a catalogue title, so it should look like
                    // catalogue search rather than like a settings input.
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppColors.surface2,
                        borderRadius: BorderRadius.circular(26),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 14),
                          // A tap target, like the Search screen's: it runs the
                          // query the same as Enter does.
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              FocusScope.of(context).unfocus();
                              cubit.search(_ctrl.text);
                            },
                            child: const Icon(
                              Icons.search_rounded,
                              size: 20,
                              color: AppColors.textTertiary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _ctrl,
                              onSubmitted: cubit.search,
                              textInputAction: TextInputAction.search,
                              style: AppText.body.copyWith(
                                color: AppColors.textPrimary,
                              ),
                              cursorColor: AppColors.accent,
                              decoration: InputDecoration(
                                hintText: l10n.searchThisSource,
                                hintStyle: AppText.body,
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 11,
                                ),
                              ),
                            ),
                          ),
                          // The field opens pre-filled with the title, so
                          // searching for something else means clearing it
                          // first. Keeps the pill's right inset when hidden.
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _ctrl,
                            builder: (context, value, _) => value.text.isEmpty
                                ? const SizedBox(width: 14)
                                : IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 18,
                                      color: AppColors.textTertiary,
                                    ),
                                    tooltip: context.l10n.clear,
                                    onPressed: () => _ctrl.clear(),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Says which query is running, not merely that one is: a
                  // source can take seconds, and after switching source this is
                  // the only thing naming what is being re-searched.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                    child: Text(
                      state.loading
                          ? '${l10n.searching}: ${state.query}'
                          : l10n.matchResultCount(state.results.length),
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: _Results(
                      state: state,
                      cellWidth: cellWidth,
                      currentUrl: currentUrl,
                      onPick: (r) async {
                        final m = await cubit.choose(r);
                        if (context.mounted) Navigator.of(context).pop(m);
                      },
                      onChangeSource: () => _openSourcePicker(cubit),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The source being searched, as a button. Named "Searching X" rather than
/// "Source: X" because that is what it is doing — the results below came from
/// it, and changing it re-runs the query.
class _SourcePill extends StatelessWidget {
  const _SourcePill({required this.sourceId, required this.onTap});
  final String sourceId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 170),
        padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The source NAME carries the meaning here — "Searching" is the
            // same on every source — so it gets the readable colour and the
            // verb stays quiet.
            Flexible(
              child: Builder(
                builder: (context) {
                  final name = sl<SourceRepository>().displayName(sourceId);
                  final full = context.l10n.searchingSourceShort(name);
                  final at = full.lastIndexOf(name);
                  // Fall back to one flat span if a translation drops or
                  // reorders the placeholder rather than guessing at a split.
                  if (at < 0) {
                    return Text(
                      full,
                      style: AppText.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    );
                  }
                  return Text.rich(
                    TextSpan(
                      style: AppText.caption.copyWith(
                        color: AppColors.textTertiary,
                      ),
                      children: [
                        TextSpan(text: full.substring(0, at)),
                        TextSpan(
                          text: name,
                          style: AppText.caption.copyWith(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(text: full.substring(at + name.length)),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  );
                },
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 16,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Results, loading and empty — one widget so the three states can never be
/// shown at once, which is how "no results" used to look identical to "still
/// searching": both drew an empty list.
class _Results extends StatelessWidget {
  const _Results({
    required this.state,
    required this.cellWidth,
    required this.currentUrl,
    required this.onPick,
    required this.onChangeSource,
  });

  final WrongTitleState state;
  final double cellWidth;
  final String? currentUrl;
  final ValueChanged<MediaItem> onPick;
  final VoidCallback onChangeSource;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final aspect = posterCellAspect(cellWidth);
    final isTv = sl<AppMode>().isTv;
    if (state.results.isEmpty) {
      if (state.loading) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SkeletonGrid(crossAxisCount: 3, childAspectRatio: aspect),
        );
      }
      return EmptyState(
        icon: Icons.search_off_rounded,
        message: l10n.sourceMayNotCarryIt,
        actionLabel: l10n.chooseSource,
        onAction: onChangeSource,
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      // Both copied from the metadata results grid, and both are why scrolling
      // felt different here: without the cache extent a row is built as it
      // enters the viewport and its cover pops in mid-scroll, and without the
      // dismiss behaviour the keyboard stays up over the results you are
      // scrolling to — this sheet always opens with a focusable field.
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: aspect,
        crossAxisSpacing: 12,
        mainAxisSpacing: 16,
      ),
      itemCount: state.results.length,
      itemBuilder: (_, i) {
        final r = state.results[i];
        // A source can answer with five results all titled the same — the
        // cover is the only thing that separates them, so it is the whole
        // cell. Marking the one already pinned stops it being re-picked as
        // though it were a different show.
        final isCurrent = currentUrl != null && r.url == currentUrl;
        Widget cell = PosterCard(
          title: r.title,
          imageUrl: r.cover,
          headers: r.coverHeaders,
          cellWidth: cellWidth,
          qualityBadge: r.quality,
          dubBadge: r.dubBadge,
          tags: isCurrent ? [l10n.currentMatchBadge] : const [],
          // On TV the TvFocusable below owns OK, so the card must not also
          // claim the tap — see the TV rails for the same pairing.
          onTap: isTv ? null : () => onPick(r),
        );
        if (isTv) {
          // PosterCard is a bare GestureDetector, which the D-pad cannot
          // reach. The ListTile this replaced was focusable for free, so
          // without this the sheet is unusable on TV — and TV's Detail
          // screen does show "Wrong title?".
          cell = TvFocusable(
            autofocus: i == 0,
            variant: TvFocusVariant.float,
            scale: 1.06,
            onTap: () => onPick(r),
            semanticLabel: r.title,
            child: cell,
          );
        }
        // The same staggered entrance My List uses, so a sheetful of posters
        // cascades in instead of appearing as one block. Self-gating: returns
        // the child untouched on TV or with list animations off.
        return RevealItem(index: i, child: cell);
      },
    );
  }
}
