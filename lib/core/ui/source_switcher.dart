import 'package:flutter/material.dart';

import '../di/injector.dart';
import '../provider/provider_registry.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// A compact pill button that shows the active source and opens a
/// bottom-sheet picker when tapped. The selectable list is built
/// dynamically from the installed-and-enabled providers in
/// [ProviderRegistry], so repo-installed sources become selectable here
/// as soon as they're enabled.
class SourceSwitcher extends StatelessWidget {
  const SourceSwitcher({
    super.key,
    required this.currentId,
    required this.onChanged,
  });

  final String currentId;
  final void Function(String id) onChanged;

  /// Installed + enabled providers, mapped to `{id, label}` rows.
  List<({String id, String label})> _selectable() {
    final entries =
        sl<ProviderRegistry>().getAll().where((e) => e.enabled).toList()
          ..sort((a, b) {
            final an = a.displayName.isNotEmpty ? a.displayName : a.name;
            final bn = b.displayName.isNotEmpty ? b.displayName : b.name;
            return an.toLowerCase().compareTo(bn.toLowerCase());
          });
    return [
      for (final e in entries)
        (id: e.name, label: e.displayName.isNotEmpty ? e.displayName : e.name),
    ];
  }

  String get _label {
    final entry = sl<ProviderRegistry>().entryFor(currentId);
    if (entry != null && entry.displayName.isNotEmpty) return entry.displayName;
    return entry?.name ?? currentId;
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
    final sources = _selectable();
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
              if (sources.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text('No enabled sources', style: AppText.body),
                )
              else
                ...sources.map((src) {
                  final isActive = src.id == currentId;
                  return _SourceRow(
                    label: src.label,
                    isActive: isActive,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      onChanged(src.id);
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
    required this.isActive,
    required this.onTap,
  });

  final String label;
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
            Expanded(child: Text(label, style: AppText.headline)),
            if (isActive)
              const Icon(Icons.check, color: AppColors.accent, size: 20),
          ],
        ),
      ),
    );
  }
}
