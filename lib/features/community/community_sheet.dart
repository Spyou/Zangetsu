import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';

const _telegramUrl = 'https://t.me/ZangetsuStream';
const _discordUrl = 'https://discord.gg/f9cKxR9cz';
const _flagsBox = 'app_flags';
const _seenKey = 'communitySheetSeen';

/// One-time "join the community" bottom sheet, shown once per install (new and
/// existing users) on launch, then never again. Gated by its OWN Hive flag —
/// independent of the per-id announcement system, so future announcements still
/// show. Fire-and-forget; never throws (a welcome must not block startup).
Future<void> maybeShowCommunitySheet(BuildContext context) async {
  try {
    final box = Hive.isBoxOpen(_flagsBox)
        ? Hive.box(_flagsBox)
        : await Hive.openBox(_flagsBox);
    if (box.get(_seenKey) == true) return;
    if (!context.mounted) return;
    await showCommunitySheet(context);
    // Mark seen after it's shown; if the app is killed mid-sheet it may show
    // once more next launch — acceptable, and safer than never showing it.
    await box.put(_seenKey, true);
  } catch (_) {
    // Never break launch on the welcome sheet.
  }
}

/// Show the community sheet directly (bypasses the seen-flag) — e.g. a future
/// "Community" entry in Settings could reuse this.
Future<void> showCommunitySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    useRootNavigator: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const _CommunitySheet(),
  );
}

class _CommunitySheet extends StatelessWidget {
  const _CommunitySheet();

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // A missing browser/app shouldn't crash — silently ignore.
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTv = sl<AppMode>().isTv;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: AppColors.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.groups_rounded,
                      color: AppColors.accent, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Join the Zangetsu community',
                    style: AppText.headline.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Updates, requests, and help — come say hi.',
              style: AppText.body.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 22),
            _linkButton(
              context,
              icon: Icons.send_rounded,
              label: 'Telegram  ·  @ZangetsuStream',
              color: const Color(0xFF229ED9),
              url: _telegramUrl,
              autofocus: isTv, // first button gets D-pad focus on TV
              isTv: isTv,
            ),
            const SizedBox(height: 12),
            _linkButton(
              context,
              icon: Icons.forum_rounded,
              label: 'Discord',
              color: const Color(0xFF5865F2),
              url: _discordUrl,
              autofocus: false,
              isTv: isTv,
            ),
            const SizedBox(height: 6),
            Center(child: _laterButton(context, isTv: isTv)),
          ],
        ),
      ),
    );
  }

  Widget _linkButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required String url,
    required bool autofocus,
    required bool isTv,
  }) {
    void go() {
      Navigator.of(context).pop();
      _open(url);
    }

    final button = FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
        alignment: Alignment.centerLeft,
      ),
      onPressed: go,
      icon: Icon(icon),
      label: Text(label),
    );
    if (!isTv) return button;
    // On TV the D-pad drives focus; TvFocusable handles OK-key activation.
    return TvFocusable(scale: 1.0, autofocus: autofocus, onTap: go, child: button);
  }

  Widget _laterButton(BuildContext context, {required bool isTv}) {
    void dismiss() => Navigator.of(context).pop();
    final button = TextButton(
      onPressed: dismiss,
      child: Text('Maybe later',
          style: AppText.body.copyWith(color: AppColors.textTertiary)),
    );
    if (!isTv) return button;
    return TvFocusable(scale: 1.0, onTap: dismiss, child: button);
  }
}
