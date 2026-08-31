import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';

/// Beginner-friendly "how the app works" content — a few one-line tips plus a
/// short FAQ. Reused by the onboarding "you're all set" step AND the
/// Settings → How it works page, so the guidance lives in ONE place.
class HowItWorksView extends StatelessWidget {
  const HowItWorksView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Text(context.l10n.howToUseTheApp, style: AppText.title.copyWith(fontSize: 20)),
        const SizedBox(height: 4),
        Text(
          context.l10n.aFewTapsToAnything,
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
        const SizedBox(height: 18),
        _Tip(
          icon: Icons.search_rounded,
          title: context.l10n.findSomething,
          body: context.l10n.scrollRowsOrSearch,
        ),
        _Tip(
          icon: Icons.play_circle_outline,
          title: context.l10n.watchIt,
          body: context.l10n.openTitleAndPlay,
        ),
        _Tip(
          icon: Icons.swap_horiz_rounded,
          title: context.l10n.ifItWontLoad,
          body: context.l10n.switchSourceAtTop,
        ),
        _Tip(
          icon: Icons.download_outlined,
          title: context.l10n.saveForOffline,
          body: context.l10n.tapDownloadForOffline,
        ),
        const SizedBox(height: 24),
        Text(
          context.l10n.commonQuestions,
          style: AppText.body.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        _Faq(
          q: context.l10n.faqSourceNotWorkingQ,
          a: context.l10n.faqSourceNotWorkingA,
        ),
        _Faq(
          q: context.l10n.faqSubOrDubQ,
          a: context.l10n.faqSubOrDubA,
        ),
        _Faq(
          q: context.l10n.faqDownloadsQ,
          a: context.l10n.faqDownloadsA,
        ),
      ],
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.accentSoft,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: AppColors.accent, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: AppText.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                body,
                style: AppText.caption.copyWith(
                  color: AppColors.textSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Faq extends StatelessWidget {
  const _Faq({required this.q, required this.a});

  final String q;
  final String a;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          q,
          style: AppText.body.copyWith(
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          a,
          style: AppText.caption.copyWith(
            color: AppColors.textSecondary,
            height: 1.35,
          ),
        ),
      ],
    ),
  );
}

/// Standalone page for Settings → How it works (revisitable any time).
class HowItWorksScreen extends StatelessWidget {
  const HowItWorksScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.bg,
    appBar: AppBar(
      backgroundColor: AppColors.bg,
      elevation: 0,
      title: Text(context.l10n.howItWorks, style: AppText.title.copyWith(fontSize: 18)),
    ),
    body: const SafeArea(child: HowItWorksView()),
  );
}
