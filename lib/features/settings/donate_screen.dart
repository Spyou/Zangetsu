import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_config.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// Support / Donate screen — a short message and a Buy Me a Coffee link.
class DonateScreen extends StatelessWidget {
  const DonateScreen({super.key});

  static const String _bmcUrl = 'https://buymeacoffee.com/krishna069';

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        title: Text('Support', style: AppText.title),
        centerTitle: true,
      ),
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
                Icons.coffee_rounded,
                color: AppColors.accent,
                size: 42,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Center(
            child: Text(
              'Enjoying $kAppName?',
              style: AppText.largeTitle.copyWith(fontSize: 23),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            "$kAppName is free and ad-free. If it's earned a spot on your home "
            'screen, a small tip keeps it growing — new features, fixes and '
            'faster updates. Every coffee genuinely helps. Thank you! ♥',
            style: AppText.body.copyWith(height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          _BmcButton(onTap: () => _open(_bmcUrl)),
          const SizedBox(height: 12),
          Center(
            child: Text(
              'buymeacoffee.com/krishna069',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Buy Me a Coffee button in its recognizable brand yellow.
class _BmcButton extends StatelessWidget {
  const _BmcButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            color: const Color(0xFFFFDD00),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFDD00).withValues(alpha: 0.3),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.coffee_rounded, color: Color(0xFF13110A), size: 22),
                SizedBox(width: 10),
                Text(
                  'Buy me a coffee',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    letterSpacing: -0.2,
                    color: Color(0xFF13110A),
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
