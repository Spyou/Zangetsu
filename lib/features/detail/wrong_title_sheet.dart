import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/di/injector.dart';
import '../../core/repository/source_repository.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/zmode/match_store.dart';
import '../../core/zmode/source_matcher.dart';
import '../../core/zmode/zmode_ids.dart';
import '../../l10n/l10n.dart';
import 'cubit/wrong_title_cubit.dart';

/// "Source: AllAnime · Wrong title?" under a metadata title. Resolves the match
/// on first build; the link opens [showWrongTitleSheet] and re-resolves after.
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
  late Future<SourceMatch?> _match = _resolve();

  Future<SourceMatch?> _resolve() => sl<SourceMatcher>().resolve(
    widget.canonical,
    title: widget.title,
    altTitle: widget.altTitle,
    malId: widget.malId,
  );

  Future<void> _fix() async {
    final picked = await showWrongTitleSheet(
      context,
      canonical: widget.canonical,
      title: widget.title,
    );
    if (picked == null || !mounted) return;
    // A block body, not `=> _match = ...` — that arrow's value is the
    // assignment's Future, and setState() rejects a callback that returns one.
    setState(() {
      _match = Future.value(picked);
    });
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(context.l10n.matchSaved(
        sl<SourceRepository>().displayName(picked.sourceId)))));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<SourceMatch?>(
      future: _match,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(height: 20);
        }
        final m = snap.data;
        final label = m == null
            ? l10n.noSourceHasThisYet
            : l10n.sourceLabel(sl<SourceRepository>().displayName(m.sourceId));
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Icon(Icons.hub_outlined, size: 15,
                  color: m == null ? AppColors.textTertiary : AppColors.textSecondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label, style: AppText.caption,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 10),
              InkWell(
                onTap: _fix,
                child: Text(l10n.wrongTitle,
                    style: AppText.caption.copyWith(color: AppColors.accent)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Pick a source, search it, tap the right result. Returns the pinned match.
Future<SourceMatch?> showWrongTitleSheet(
  BuildContext context, {
  required ZCanonical canonical,
  required String title,
}) {
  return showModalBottomSheet<SourceMatch>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _WrongTitleBody(canonical: canonical, initialQuery: title),
  );
}

class _WrongTitleBody extends StatelessWidget {
  const _WrongTitleBody({required this.canonical, required this.initialQuery});
  final ZCanonical canonical;
  final String initialQuery;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => WrongTitleCubit(
        sources: sl<SourceRepository>(),
        matcher: sl<SourceMatcher>(),
        canonical: canonical,
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
    final sources = cubit.sources;
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
                const SizedBox(height: 10),
                if (sources.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(l10n.noSourceHasThisYet, style: AppText.body),
                    ),
                  )
                else ...[
                  SizedBox(
                    height: 40,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: [
                        for (final s in sources)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(s.name),
                              selected: s.id == state.sourceId,
                              onSelected: (_) {
                                cubit.pickSource(s.id);
                                cubit.search(_ctrl.text);
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
