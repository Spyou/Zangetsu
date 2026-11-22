import 'package:flutter/material.dart';
import '../../core/ui/settings_widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_config.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../l10n/l10n.dart';

/// Support / Donate screen — a short message and one way to tip: Buy Me a
/// Coffee. The PayPal and UPI buttons were removed along with their handlers
/// and destinations.
class DonateScreen extends StatelessWidget {
  const DonateScreen({super.key});

  static const String _bmcUrl = 'https://buymeacoffee.com/AniAura6';

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(context.l10n.supportTitle),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
        children: [
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: AppColors.accentSoft,
                borderRadius: BorderRadius.circular(24),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.favorite_rounded,
                color: AppColors.accent,
                size: 40,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Center(
            child: Text(
              context.l10n.enjoyingApp(kAppName),
              style: AppText.largeTitle.copyWith(fontSize: 23),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            context.l10n.donateBlurb(kAppName),
            style: AppText.body.copyWith(height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          _DonateButton(
            label: context.l10n.buyMeACoffee,
            icon: Icons.coffee_rounded,
            bg: const Color(0xFFFFDD00),
            fg: const Color(0xFF13110A),
            onTap: () => _open(_bmcUrl),
          ),
        ],
      ),
    );
  }
}

/// A pill donate button — brand-coloured, icon + label.
class _DonateButton extends StatelessWidget {
  const _DonateButton({
    required this.label,
    required this.icon,
    required this.bg,
    required this.fg,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color bg;
  final Color fg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
    final button = Container(
      height: 54,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: bg.withValues(alpha: 0.3),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fg, size: 22),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontFamily: AppText.fontFamily,
          fontFamilyFallback: AppText.fontFamilyFallback,
                fontWeight: FontWeight.w700,
                fontSize: 16,
                letterSpacing: -0.2,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
    if (isTv) {
      return TvFocusable(
        variant: TvFocusVariant.pill,
        semanticLabel: label,
        onTap: onTap,
        child: button,
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: button,
      ),
    );
  }
}
