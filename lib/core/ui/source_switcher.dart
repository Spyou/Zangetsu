import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Metadata for sources the user can select at runtime.
const kSelectableSources = <Map<String, String>>[
  {'id': 'allanime', 'label': 'AllAnime', 'sub': 'Anime'},
  {'id': 'netmirror_nf', 'label': 'Netflix', 'sub': 'Movies & TV'},
  {'id': 'netmirror_pv', 'label': 'Prime Video', 'sub': 'Movies & TV'},
  {'id': 'netmirror_hs', 'label': 'Hotstar', 'sub': 'Movies & TV'},
  {'id': 'netmirror_dp', 'label': 'Disney+', 'sub': 'Movies & TV'},
];

/// A compact pill button that shows the active source and opens a bottom-sheet
/// picker when tapped.
class SourceSwitcher extends StatelessWidget {
  const SourceSwitcher({
    super.key,
    required this.currentId,
    required this.onChanged,
  });

  final String currentId;
  final void Function(String id) onChanged;

  String get _label {
    for (final src in kSelectableSources) {
      if (src['id'] == currentId) return src['label']!;
    }
    return currentId;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showPicker(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface2,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label,
              style: AppText.body.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down,
              size: 16,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  void _showPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
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
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Text(
                  'Choose Source',
                  style: AppText.overline.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
              const Divider(color: AppColors.hairline, height: 1),
              ...kSelectableSources.map((src) {
                final isActive = src['id'] == currentId;
                return _SourceRow(
                  label: src['label']!,
                  sub: src['sub']!,
                  isActive: isActive,
                  onTap: () {
                    Navigator.of(ctx).pop();
                    onChanged(src['id']!);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.label,
    required this.sub,
    required this.isActive,
    required this.onTap,
  });

  final String label;
  final String sub;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      splashColor: AppColors.accent.withValues(alpha: 0.08),
      highlightColor: AppColors.accent.withValues(alpha: 0.04),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppText.headline),
                  const SizedBox(height: 2),
                  Text(sub, style: AppText.caption),
                ],
              ),
            ),
            if (isActive)
              const Icon(
                Icons.check,
                color: AppColors.accent,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
