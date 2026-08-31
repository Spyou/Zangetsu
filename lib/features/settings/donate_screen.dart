import 'package:flutter/material.dart';
import '../../core/ui/settings_widgets.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_config.dart';
import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../../l10n/l10n.dart';
import '../../core/tv/tv_list_focusable.dart';

/// Support / Donate screen — a short message and a few ways to tip:
/// Buy Me a Coffee, PayPal (international) and UPI (India).
class DonateScreen extends StatelessWidget {
  const DonateScreen({super.key});

  static const String _bmcUrl = 'https://buymeacoffee.com/krishna069';
  static const String _paypalUrl = 'https://paypal.me/SpyTheSaviour';
  static const String _upiId = 'krishnavishwakarma9136@okaxis';

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  /// Open the UPI ID in whichever UPI app the user has. If none can handle it
  /// (no UPI app, or desktop), fall back to copying the ID so they can paste it.
  Future<void> _payUpi(BuildContext context) async {
    // Leave the '@' in the VPA literal — that's what UPI apps expect.
    final uri = Uri.parse(
        'upi://pay?pa=$_upiId&pn=${Uri.encodeComponent(kAppName)}&cu=INR');
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // no app registered for upi:// — fall through to copy
    }
    if (context.mounted) _copyUpi(context, noApp: true);
  }

  void _copyUpi(BuildContext context, {bool noApp = false}) {
    Clipboard.setData(const ClipboardData(text: _upiId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(noApp
            ? context.l10n.noUPIAppFoundUPIIDCopiedPasteItInYourUPIApp
            : context.l10n.upiIdCopied),
      ),
    );
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
          const SizedBox(height: 12),
          _DonateButton(
            label: context.l10n.donateWithPayPal,
            icon: Icons.account_balance_wallet_rounded,
            bg: const Color(0xFF003087),
            fg: Colors.white,
            onTap: () => _open(_paypalUrl),
          ),
          const SizedBox(height: 20),
          // UPI — India. Separate little block with a copyable ID so it works
          // even when the deep link can't open an app.
          Row(
            children: [
              Expanded(child: Divider(color: AppColors.textTertiary.withValues(alpha: 0.2))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(context.l10n.upiIndia,
                    style: AppText.caption.copyWith(color: AppColors.textTertiary)),
              ),
              Expanded(child: Divider(color: AppColors.textTertiary.withValues(alpha: 0.2))),
            ],
          ),
          const SizedBox(height: 16),
          _DonateButton(
            label: context.l10n.payViaUPI,
            icon: Icons.currency_rupee_rounded,
            bg: AppColors.accent,
            fg: Colors.white,
            onTap: () => _payUpi(context),
          ),
          const SizedBox(height: 12),
          // Tap the ID to copy — handy on desktop or when the button can't
          // reach a UPI app.
          Center(
            child: (sl.isRegistered<AppMode>() && sl<AppMode>().isTv)
                ? TvListFocusable(
                    semanticLabel: context.l10n.copyUPIID,
                    onTap: () => _copyUpi(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _upiId,
                            style: AppText.caption
                                .copyWith(color: AppColors.textSecondary),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.copy_rounded,
                              size: 14, color: AppColors.textTertiary),
                        ],
                      ),
                    ),
                  )
                : InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _copyUpi(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _upiId,
                            style: AppText.caption
                                .copyWith(color: AppColors.textSecondary),
                          ),
                          const SizedBox(width: 6),
                          Icon(Icons.copy_rounded,
                              size: 14, color: AppColors.textTertiary),
                        ],
                      ),
                    ),
                  ),
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
                fontFamily: 'Inter',
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
