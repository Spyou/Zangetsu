import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/aniyomi/aniyomi_extension_service.dart';
import '../../core/di/injector.dart';
import '../../core/mihon/mihon_extension_service.dart';
import '../../core/provider/cloudstream_provider.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/ui/source_switcher.dart';
import '../../core/theme/app_text.dart';
import '../../core/zmode/match_store.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../core/zmode/zmode_module.dart';
import '../../l10n/l10n.dart';
import '../sources/source_settings_screen.dart';
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
  void _refreshAfterMatchChange() => context.read<DetailCubit>().refresh();

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
      onPick: (id) async {
        if (id == state.selectedId) return;
        await _cubit.selectSource(id);
        if (mounted) _refreshAfterMatchChange();
      },
    );
  }

  Future<bool> _hasSourceSettings(String id) {
    if (id.startsWith('ani:')) {
      final raw = int.tryParse(id.substring(4));
      return raw == null
          ? Future.value(false)
          : AniyomiExtensionService().hasSourceSettings(raw);
    }
    if (id.startsWith('mihon:')) {
      final raw = int.tryParse(id.substring(6));
      return raw == null
          ? Future.value(false)
          : MihonExtensionService().hasSourceSettings(raw);
    }
    if (id.startsWith('cs:')) return csPluginHasSettings(id.substring(3));
    return Future.value(false);
  }

  Future<void> _openSourceSettings(
    BuildContext context,
    String id,
    String name,
  ) async {
    if (id.startsWith('ani:')) {
      final raw = int.tryParse(id.substring(4));
      if (raw != null) await AniyomiExtensionService().openSourceSettings(raw);
      return;
    }
    if (id.startsWith('mihon:')) {
      final raw = int.tryParse(id.substring(6));
      if (raw != null) await MihonExtensionService().openSourceSettings(raw);
      return;
    }
    if (id.startsWith('cs:') && context.mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              SourceSettingsScreen(sourceId: id, repoUrl: '', displayName: name),
        ),
      );
    }
  }

  /// Per-source controls on a picker row: solve Cloudflare, and open that
  /// source's own settings. Each is shown only when it will actually do
  /// something, and neither changes the selection — tapping the row body does.
  Widget _rowActions(BuildContext sheetContext, String id) {
    // Home already routes Mihon, Aniyomi and LNReader challenges through this
    // one solver, and those are exactly the ecosystems baseUrlFor answers for.
    // CloudStream/JS items are absolute and return '', which doubles as the
    // honest signal that there is no site to solve against.
    final cloudflareUrl = sl<SourceRepository>().baseUrlFor(id);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (cloudflareUrl.isNotEmpty)
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: sheetContext.l10n.solveCloudflare,
            icon: const Icon(Icons.shield_rounded, size: 18),
            color: AppColors.textSecondary,
            onPressed: () =>
                MihonExtensionService.solveCloudflare(cloudflareUrl),
          ),
        FutureBuilder<bool>(
          future: _hasSourceSettings(id),
          builder: (context, snapshot) {
            if (snapshot.data != true) return const SizedBox.shrink();
            return IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: sheetContext.l10n.sourceSettings,
              icon: const Icon(Icons.tune_rounded, size: 18),
              color: AppColors.textSecondary,
              onPressed: () => _openSourceSettings(
                sheetContext,
                id,
                sl<SourceRepository>().displayName(id),
              ),
            );
          },
        ),
      ],
    );
  }

  Future<void> _fix(String sourceId) async {
    final picked = await showWrongTitleSheet(
      context,
      canonical: widget.canonical,
      title: widget.title,
      sourceId: sourceId,
    );
    if (picked == null || !mounted) return;
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
    return BlocProvider.value(
      value: _cubit,
      child: BlocBuilder<SourceSelectCubit, SourceSelectState>(
        builder: (context, state) {
          if (state.sources.isEmpty) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  Icon(Icons.hub_outlined, size: 15, color: AppColors.textTertiary),
                  const SizedBox(width: 6),
                  Text(l10n.noSourceHasThisYet, style: AppText.caption),
                ],
              ),
            );
          }
          if (state.loading && state.selectedId == null) {
            return const SizedBox(height: 20); // first resolve still in flight
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
              ? l10n.noSourceHasThisYet
              : sl<SourceRepository>().displayName(selectedId);
          final hasMatch = state.match != null;
          // Sized and filled like _DownloadButton directly above, so Play,
          // Download and Source read as one stack. The row body opens the
          // picker; the trailing icons act on the SELECTED source and are
          // outside that InkWell so they never double as a row tap.
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
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
                              child: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      label,
                                      style: AppText.button.copyWith(
                                        // Dimmed when nothing matched — the row
                                        // still opens the picker, but there is
                                        // no source behind it yet.
                                        color: hasMatch
                                            ? AppColors.textPrimary
                                            : AppColors.textTertiary,
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
                              ),
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
                  InkWell(
                    onTap: () => _fix(selectedId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
                      child: Text(
                        l10n.wrongTitle,
                        style: AppText.caption.copyWith(color: AppColors.accent),
                      ),
                    ),
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cubit = context.read<WrongTitleCubit>();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: BlocBuilder<WrongTitleCubit, WrongTitleState>(
            builder: (context, state) => Column(
              children: [
                const SizedBox(height: 12),
                Text(l10n.pickTheRightTitle, style: AppText.headline),
                const SizedBox(height: 2),
                Text(l10n.sourceLabel(sl<SourceRepository>().displayName(cubit.sourceId)),
                    style: AppText.caption.copyWith(color: AppColors.textSecondary)),
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
                if (state.loading) const LinearProgressIndicator(minHeight: 2),
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
