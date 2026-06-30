import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

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
        Text('How to use the app', style: AppText.title.copyWith(fontSize: 20)),
        const SizedBox(height: 4),
        Text(
          'A few taps to anything.',
          style: AppText.caption.copyWith(color: AppColors.textTertiary),
        ),
        const SizedBox(height: 18),
        const _Tip(
          icon: Icons.search_rounded,
          title: 'Find something',
          body: 'Scroll the rows on Home, or tap Search at the bottom.',
        ),
        const _Tip(
          icon: Icons.play_circle_outline,
          title: 'Watch it',
          body: 'Open a title and tap Play. For a series, pick an episode first.',
        ),
        const _Tip(
          icon: Icons.swap_horiz_rounded,
          title: "If it won't load",
          body: 'Tap the source name at the top and switch to another source.',
        ),
        const _Tip(
          icon: Icons.download_outlined,
          title: 'Save for offline',
          body: 'On a title, tap Download — watch it later under Downloads.',
        ),
        const SizedBox(height: 24),
        Text(
          'Common questions',
          style: AppText.body.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const _Faq(
          q: "A source isn't working?",
          a: 'Sources come and go. Switch source from the top, or check '
              'Settings → Source health.',
        ),
        const _Faq(
          q: 'Sub or Dub?',
          a: 'Use the Sub / Dub toggle on an anime title.',
        ),
        const _Faq(
          q: 'Where are my downloads?',
          a: 'Settings → Downloads — watch them offline anytime.',
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
      title: Text('How it works', style: AppText.title.copyWith(fontSize: 18)),
    ),
    body: const SafeArea(child: HowItWorksView()),
  );
}
