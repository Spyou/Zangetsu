import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../core/zmode/zmode_prefs.dart';
import '../../l10n/l10n.dart';
import '../home/cubit/home_cubit.dart';

/// TV has no dock, so the rail gets a page with the two streaming kinds.
/// Reading modes are phone-only, so there is nothing else to offer here.
class TvModePage extends StatelessWidget {
  const TvModePage({super.key, this.reloadHome = true});

  /// Off in tests, where no HomeCubit is registered.
  final bool reloadHome;

  Future<void> _pick(StreamKind k) async {
    await ZModePrefs.setStreamKind(k);
    if (reloadHome && sl.isRegistered<HomeCubit>()) {
      sl<HomeCubit>().load(reset: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final current = ZModePrefs.streamKind;
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ModeCard(
            label: l10n.modeAnime,
            icon: Icons.play_circle_outline_rounded,
            selected: current == StreamKind.anime,
            autofocus: true,
            onTap: () => _pick(StreamKind.anime),
          ),
          const SizedBox(width: 28),
          _ModeCard(
            label: l10n.modeMovieTv,
            icon: Icons.movie_outlined,
            selected: current == StreamKind.movie,
            onTap: () => _pick(StreamKind.movie),
          ),
        ],
      ),
    );
  }
}

/// Large D-pad-focusable card — same float-outline focus chrome as posters
/// and source rows elsewhere on TV; the accent border marks the current pick.
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      variant: TvFocusVariant.float,
      borderRadius: 18,
      autofocus: autofocus,
      semanticLabel: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Container(
          width: 220,
          height: 160,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? AppColors.accent : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 44, color: AppColors.textPrimary),
              const SizedBox(height: 12),
              Text(label, style: AppText.headline),
            ],
          ),
        ),
      ),
    );
  }
}
