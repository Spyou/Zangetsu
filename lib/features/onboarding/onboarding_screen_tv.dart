import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../core/app_config.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/tv/tv_focusable.dart';
import '../sources/providers_hub_screen.dart';

Future<void> _markOnboarded() =>
    Hive.box(ActiveSourceCubit.boxName).put('onboarded', true);

/// TV-adapted first-run onboarding. Same no-install, "add your own sources"
/// copy as the phone [OnboardingScreen] — only the interaction model changes:
/// every action button is a [TvFocusable] so the D-pad reaches it and OK
/// activates it.
class OnboardingScreenTv extends StatefulWidget {
  const OnboardingScreenTv({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<OnboardingScreenTv> createState() => _OnboardingScreenTvState();
}

class _OnboardingScreenTvState extends State<OnboardingScreenTv> {
  /// Marks onboarding done, hands off to the app, then opens Providers so the
  /// user lands right where they add a repository. No network call, no
  /// install — the app just navigates.
  Future<void> _addSourcesNow() async {
    await _markOnboarded();
    if (!mounted) return;
    widget.onDone();
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ProvidersHubScreen()));
  }

  Future<void> _later() async {
    await _markOnboarded();
    if (mounted) widget.onDone();
  }

  Widget _bullet(IconData icon, String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      children: [
        Icon(icon, color: AppColors.accent, size: 20),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            label,
            style: AppText.body.copyWith(color: AppColors.textPrimary),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: SizedBox(
            width: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Spacer(flex: 2),
                Text(
                  'Welcome to $kAppName',
                  style: AppText.title,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  '$kAppName comes with no sources built in — you add your own. '
                  'Add a repository and pick what to install, any time from '
                  'Settings → Providers.',
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 26),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _bullet(Icons.explore_outlined, 'Open Providers'),
                    _bullet(
                      Icons.category_outlined,
                      'Pick an ecosystem — Streaming, Manga or Novel',
                    ),
                    _bullet(
                      Icons.link_rounded,
                      'Add a repository by pasting its URL',
                    ),
                    _bullet(
                      Icons.download_outlined,
                      'Browse it and install what you want',
                    ),
                  ],
                ),
                const Spacer(flex: 3),
                TvFocusable(
                  autofocus: true,
                  onTap: _addSourcesNow,
                  // ExcludeFocus: a Flutter button is focusable in its own
                  // right, so without this the D-pad stops on the inner button
                  // as well as the TvFocusable around it — down from here would
                  // land on itself instead of the next action. Every other TV
                  // screen wraps a plain Container for the same reason.
                  child: ExcludeFocus(
                    child: SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton(
                        onPressed: _addSourcesNow,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          'Add sources now',
                          style: AppText.button.copyWith(color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TvFocusable(
                  autofocus: false,
                  onTap: _later,
                  child: ExcludeFocus(
                    child: SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: TextButton(
                        onPressed: _later,
                        child: Text(
                          "I'll do it later",
                          style: AppText.caption.copyWith(
                            color: AppColors.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
