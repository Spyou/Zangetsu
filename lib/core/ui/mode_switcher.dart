import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../app_mode.dart';
import '../di/injector.dart';
import '../mode/content_mode.dart';
import '../mode/content_mode_cubit.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Compact header pill (mode icon + a dropdown caret) that opens a bottom
/// sheet to switch between Anime / Manga / Novel. Mirrors [SourceSwitcher]'s
/// pill chrome (border/radius) so the two sit together as a pair.
///
/// Reading modes are phone-only — this renders nothing on TV.
class ModeSwitcher extends StatelessWidget {
  const ModeSwitcher({super.key});

  @override
  Widget build(BuildContext context) {
    if (sl<AppMode>().isTv) return const SizedBox.shrink();
    return BlocBuilder<ContentModeCubit, ContentMode>(
      bloc: sl<ContentModeCubit>(),
      builder: (context, mode) => GestureDetector(
        onTap: () => _showPicker(context, mode),
        child: Container(
          padding: const EdgeInsets.fromLTRB(9, 4, 7, 4),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(mode.icon, size: 15, color: AppColors.textPrimary),
              const SizedBox(width: 3),
              const Icon(
                Icons.keyboard_arrow_down,
                size: 15,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Standard dark sheet chrome (grab handle + [AppColors.surface]), same as
  /// the source switcher / settings pickers.
  void _showPicker(BuildContext context, ContentMode current) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
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
            for (final m in ContentMode.values)
              ListTile(
                leading: Icon(m.icon, color: AppColors.textPrimary),
                title: Text(m.label, style: AppText.body),
                trailing: m == current
                    ? Icon(Icons.check_rounded, color: AppColors.accent)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  sl<ContentModeCubit>().setMode(m);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
