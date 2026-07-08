import 'package:flutter/material.dart';

import '../playback/subtitle_language.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Bottom sheet to pick the global subtitle preference. Returns '' (Auto),
/// 'off', a language iso1, or null when dismissed. Used by Settings and the
/// in-player Audio & Subs panel.
Future<String?> showSubtitleLanguagePicker(
  BuildContext context,
  String current,
) {
  Widget row(String label, String value) => ListTile(
        onTap: () => Navigator.pop(context, value),
        title: Text(label, style: AppText.body.copyWith(color: AppColors.textPrimary)),
        trailing: current == value
            ? const Icon(Icons.check, color: AppColors.accent)
            : null,
      );
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.6,
    ),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textTertiary.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Subtitle language', style: AppText.headline),
            ),
          ),
          const Divider(color: AppColors.hairline, height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [
                row('Auto', ''),
                row('Off', 'off'),
                for (final lang in kSubtitleLanguages) row(lang.name, lang.iso1),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
