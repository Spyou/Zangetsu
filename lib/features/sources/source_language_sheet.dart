import 'package:flutter/material.dart';

import '../../core/i18n/source_languages.dart';
import '../../core/prefs/source_lang_prefs.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../l10n/l10n.dart';

/// Multi-select language picker for the Mihon/Aniyomi catalogs. One row per
/// filterable language ([sortedSourceLangCodes]); toggling writes straight
/// through to [prefs] so the repo lists (which listen to it) re-filter live.
///
/// Unlike the LNReader picker, the list is a fixed set of languages rather than
/// one derived from the catalog — Mihon's repos are fetched lazily per-repo, so
/// the full set of languages present isn't known up front. Same reason there
/// are no per-language counts here.
Future<void> showSourceLanguageSheet(BuildContext context, LangPrefs prefs) {
  final codes = sortedSourceLangCodes();
  return showModalBottomSheet<void>(
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
            final enabled = prefs.enabled ?? defaultSourceLangs();
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
                        '${enabled.where(kSourceLanguages.containsKey).length} of ${codes.length}',
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
                      for (final code in codes)
                        CheckboxListTile(
                          value: enabled.contains(code),
                          onChanged: (v) {
                            final next = {...enabled};
                            if (v ?? false) {
                              next.add(code);
                            } else {
                              next.remove(code);
                            }
                            prefs.setEnabled(next);
                            setSheet(() {});
                          },
                          activeColor: AppColors.accent,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(sourceLangLabel(code)),
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

/// D-pad-navigable variant of [showSourceLanguageSheet] for the Aniyomi TV
/// screen — each language is a [TvFocusable] row with an accent highlight and a
/// checkbox that flips on OK.
Future<void> showSourceLanguageSheetTv(BuildContext context, LangPrefs prefs) {
  final codes = sortedSourceLangCodes();
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          final enabled = prefs.enabled ?? defaultSourceLangs();
          return Center(
            child: Container(
              width: 460,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(ctx).height * 0.82,
              ),
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                    child: Text(context.l10n.languages, style: AppText.headline),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        for (var i = 0; i < codes.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 3,
                              horizontal: 4,
                            ),
                            child: TvListFocusable(
                              autofocus: i == 0,
                              semanticLabel: sourceLangLabel(codes[i]),
                              onTap: () {
                                final next = {...enabled};
                                if (next.contains(codes[i])) {
                                  next.remove(codes[i]);
                                } else {
                                  next.add(codes[i]);
                                }
                                prefs.setEnabled(next);
                                setSheet(() {});
                              },
                              builder: (focused) {
                                final on = enabled.contains(codes[i]);
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.surface2,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        on
                                            ? Icons.check_box_rounded
                                            : Icons
                                                .check_box_outline_blank_rounded,
                                        color: on
                                            ? AppColors.accent
                                            : AppColors.textSecondary,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: ExcludeSemantics(
                                          child: Text(
                                            sourceLangLabel(codes[i]),
                                            style: AppText.body,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
