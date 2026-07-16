import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/ui/source_switcher.dart';

/// Full-screen D-pad-navigable source picker for TV.
///
/// Opened via [showDialog] from [RootShellTv]. On OK the active source is
/// updated via [ActiveSourceCubit] and the dialog closes. BACK closes without
/// changing the source (the Dialog barrier handles dismissal).
///
/// Data comes from [categorizedSources()] — same bucket function the phone
/// uses, so newly-installed providers appear here automatically.
/// The list is grouped (Anime / Movies & Series / NSFW), mirrors the phone's
/// "All" tab layout, with each source row wrapped in [TvFocusable].
class TvSourcePicker extends StatelessWidget {
  const TvSourcePicker({super.key, required this.currentId});

  final String currentId;

  @override
  Widget build(BuildContext context) {
    final buckets = categorizedSources();
    final rows = <_PickerRow>[];

    void addSection(
        String header, List<({String id, String label, String? repo})> sources) {
      if (sources.isEmpty) return;
      rows.add(_PickerRow.header(header));
      for (final s in sources) {
        rows.add(_PickerRow.source(s.id, s.label, s.repo));
      }
    }

    addSection('Anime', buckets.anime);
    addSection('Movies & Series', buckets.movies);
    addSection('NSFW', buckets.nsfw);

    if (rows.isEmpty) {
      rows.add(_PickerRow.header('No enabled sources'));
    }

    // Index of the currently-active source row, used for autofocus so D-pad
    // focus lands on the current selection when the picker opens.
    final activeIndex = rows.indexWhere((r) => r.sourceId == currentId);

    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 80, vertical: 48),
      child: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
              child: Text(
                'Select Source',
                style: AppText.title.copyWith(color: AppColors.textPrimary),
              ),
            ),
            const Divider(height: 1, color: AppColors.hairline),
            // ── Grouped source list ───────────────────────────────────────
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];

                  // Section header — not focusable
                  if (row.isHeader) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(24, 14, 24, 6),
                      child: Text(
                        row.label.toUpperCase(),
                        style: AppText.overline
                            .copyWith(color: AppColors.textTertiary),
                      ),
                    );
                  }

                  final isActive = row.sourceId == currentId;

                  return TvFocusable(
                    // The currently-active row gets autofocus so focus lands
                    // on it when the picker opens, not on the first item.
                    autofocus: index == activeIndex,
                    onTap: () {
                      context
                          .read<ActiveSourceCubit>()
                          .setSource(row.sourceId!);
                      Navigator.of(context).pop();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(row.label, style: AppText.headline),
                                if (row.repo != null &&
                                    row.repo!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      row.repo!,
                                      style: AppText.body.copyWith(
                                        fontSize: 11.5,
                                        height: 1.0,
                                        color: AppColors.textTertiary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          // Check mark on the active source row
                          if (isActive)
                            Icon(Icons.check,
                                color: AppColors.accent, size: 20),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Internal model for a row in the picker list.
/// Either a section [header] (not focusable) or a [source] entry.
class _PickerRow {
  const _PickerRow._({
    required this.label,
    required this.isHeader,
    this.sourceId,
    this.repo,
  });

  factory _PickerRow.header(String label) =>
      _PickerRow._(label: label, isHeader: true);

  factory _PickerRow.source(String id, String label, String? repo) =>
      _PickerRow._(label: label, isHeader: false, sourceId: id, repo: repo);

  final String label;
  final bool isHeader;

  /// Non-null for source rows, null for headers.
  final String? sourceId;
  final String? repo;
}
