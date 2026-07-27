import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';

/// The screen you land on after tapping the Manga card. Manga isn't built yet,
/// so this makes that explicit ("coming soon") and shows the unlock goal
/// (Telegram + GitHub milestones) with a live GitHub star count. When the goals
/// are met, a later update ships the library and this becomes its doorway.
class MangaSealScreen extends StatefulWidget {
  const MangaSealScreen({super.key});

  @override
  State<MangaSealScreen> createState() => _MangaSealScreenState();
}

class _MangaSealScreenState extends State<MangaSealScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..forward();

  int? _stars; // null = still loading / unknown

  @override
  void initState() {
    super.initState();
    _loadStars();
  }

  Future<void> _loadStars() async {
    try {
      final res = await sl<Dio>().get<dynamic>(
        kZangetsuGithubApi,
        options: Options(
          receiveTimeout: const Duration(seconds: 8),
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final n = (res.data is Map) ? res.data['stargazers_count'] : null;
      if (mounted && n is int) setState(() => _stars = n);
    } catch (_) {
      /* leave unknown — the goal text still shows */
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      /* best-effort */
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    final kanji = CurvedAnimation(
      parent: _in,
      curve: const Interval(0, 0.7, curve: Curves.easeOutBack),
    );
    final content = CurvedAnimation(
      parent: _in,
      curve: const Interval(0.35, 1, curve: Curves.easeOut),
    );

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.55),
            radius: 1.1,
            colors: [accent.withValues(alpha: 0.16), accent.withValues(alpha: 0)],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: IconButton(
                  icon: const Icon(Icons.close, color: AppColors.textSecondary),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 40, 24, 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Sealed lock, glowing.
                      ScaleTransition(
                        scale: Tween(begin: 0.7, end: 1.0).animate(kanji),
                        child: FadeTransition(
                          opacity: kanji,
                          child: Container(
                            width: 128,
                            height: 128,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  accent.withValues(alpha: 0.28),
                                  accent.withValues(alpha: 0),
                                ],
                              ),
                            ),
                            child: Icon(
                              Icons.lock_outline_rounded,
                              size: 68,
                              color: accent,
                              shadows: [Shadow(color: accent, blurRadius: 30)],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      FadeTransition(
                        opacity: content,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.12),
                            end: Offset.zero,
                          ).animate(content),
                          child: Column(
                            children: [
                              Text(
                                'COMING SOON',
                                style: AppText.overline.copyWith(
                                  color: accent,
                                  letterSpacing: 6,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Manga isn’t here yet',
                                style: AppText.largeTitle,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'It unlocks when the community grows. Hit both '
                                'marks and the next update brings the full '
                                'manga library:',
                                style: AppText.body,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 26),
                              _MilestoneTile(
                                accent: accent,
                                label: 'Telegram',
                                valueText: 'Goal · $kMangaTelegramGoal members',
                                progress: null,
                                cta: 'Join',
                                onCta: () => _open(kZangetsuTelegramUrl),
                              ),
                              const SizedBox(height: 12),
                              _MilestoneTile(
                                accent: accent,
                                label: 'GitHub stars',
                                valueText: _stars == null
                                    ? '… / $kMangaStarGoal ★'
                                    : '$_stars / $kMangaStarGoal ★',
                                progress: _stars == null
                                    ? null
                                    : (_stars! / kMangaStarGoal).clamp(0.0, 1.0),
                                cta: 'Star',
                                onCta: () => _open(kZangetsuGithubUrl),
                              ),
                              const SizedBox(height: 26),
                              Text(
                                'Manga will appear right here the moment the '
                                'seal breaks.',
                                style: AppText.caption,
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MilestoneTile extends StatelessWidget {
  const _MilestoneTile({
    required this.accent,
    required this.label,
    required this.valueText,
    required this.progress,
    required this.cta,
    required this.onCta,
  });

  final Color accent;
  final String label;
  final String valueText;
  final double? progress; // null = unknown / no bar
  final String cta;
  final VoidCallback onCta;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.headline),
                const SizedBox(height: 3),
                Text(valueText, style: AppText.caption.copyWith(color: accent)),
                if (progress != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 5,
                      backgroundColor: Colors.white10,
                      valueColor: AlwaysStoppedAnimation(accent),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: onCta,
            style: TextButton.styleFrom(
              backgroundColor: accent.withValues(alpha: 0.16),
              foregroundColor: accent,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(cta, style: AppText.button),
          ),
        ],
      ),
    );
  }
}
