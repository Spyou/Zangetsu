import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import '../../core/app_config.dart';
import '../../core/di/injector.dart';
import '../../core/provider/provider_registry.dart';
import '../../core/provider/provider_repo_registry.dart';
import '../../core/state/active_source_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../home/cubit/home_cubit.dart';

/// First-run flag, stored in the shared 'app_prefs' Hive box (opened during
/// [initDependencies]). True once the user has completed onboarding.
bool isOnboarded() =>
    Hive.box(ActiveSourceCubit.boxName).get('onboarded', defaultValue: false)
        as bool;

Future<void> _markOnboarded() =>
    Hive.box(ActiveSourceCubit.boxName).put('onboarded', true);

// ─────────────────────────────────────────────────────────────────────────────
// Splash — shown while initDependencies() runs.
// ─────────────────────────────────────────────────────────────────────────────

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..forward();

  // Glow eases in; the wordmark fades in and "draws" left→right (wipe reveal)
  // while settling up to full scale; the loader appears last.
  late final Animation<double> _glow =
      CurvedAnimation(parent: _c, curve: const Interval(0.0, 0.55, curve: Curves.easeOut));
  late final Animation<double> _fade =
      CurvedAnimation(parent: _c, curve: const Interval(0.12, 0.5, curve: Curves.easeOut));
  late final Animation<double> _reveal =
      CurvedAnimation(parent: _c, curve: const Interval(0.12, 1.0, curve: Curves.easeOutCubic));
  late final Animation<double> _loader =
      CurvedAnimation(parent: _c, curve: const Interval(0.7, 1.0, curve: Curves.easeOut));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final r = _reveal.value;
          return Stack(
            children: [
              // Soft coral glow behind the wordmark — echoes the logo's circle.
              Center(
                child: Opacity(
                  opacity: _glow.value,
                  child: Container(
                    width: 460,
                    height: 460,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          AppColors.accent.withValues(alpha: 0.18),
                          AppColors.accent.withValues(alpha: 0.05),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.45, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
              // Wordmark — wipe reveal (left→right) + fade + slight scale settle.
              Center(
                child: FractionallySizedBox(
                  widthFactor: 0.62,
                  child: Opacity(
                    opacity: _fade.value,
                    child: Transform.scale(
                      scale: 0.94 + 0.06 * r,
                      child: ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (rect) => LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: const [
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                          ],
                          stops: [
                            0.0,
                            (r - 0.07).clamp(0.0, 1.0),
                            r.clamp(0.0001, 1.0),
                          ],
                        ).createShader(rect),
                        child: Image.asset(
                          'assets/icon/wordmark.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Minimal loader, low and quiet.
              Align(
                alignment: const Alignment(0, 0.8),
                child: Opacity(
                  opacity: _loader.value,
                  child: const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) => Container(
    width: 84,
    height: 84,
    decoration: BoxDecoration(
      color: AppColors.accentSoft,
      borderRadius: BorderRadius.circular(22),
    ),
    alignment: Alignment.center,
    child: const Icon(
      Icons.play_circle_fill_rounded,
      color: AppColors.accent,
      size: 46,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Onboarding — first launch. Downloads the official Zangetsu provider repo and
// installs its sources, then hands off to the app via [onDone].
// ─────────────────────────────────────────────────────────────────────────────

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onDone});

  /// Called once setup completes (or is skipped) — the boot gate then shows
  /// the app shell.
  final VoidCallback onDone;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _busy = false;
  String? _error;
  String _status = '';

  Future<void> _setup() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Downloading source catalog…';
    });
    try {
      final repos = sl<ProviderReposRegistry>();
      final registry = sl<ProviderRegistry>();
      final repo = await repos.fetchAndCache(kZangetsuRepoUrl);
      final total = repo.sources.length;
      var installed = 0;
      for (final s in repo.sources) {
        if (!mounted) return;
        setState(() => _status = 'Installing ${s.name}… (${installed + 1}/$total)');
        try {
          await registry.install(
            sourceId: s.id,
            fileUrl: repos.resolveFileUrl(repo, s),
            repoUrl: repo.url,
            displayName: s.name,
            version: s.version,
            force: true,
          );
          installed++;
        } catch (_) {
          // Skip a single failed source; keep installing the rest.
        }
      }
      if (installed == 0) {
        throw Exception('No sources could be installed');
      }
      // Activate the first source so Home has something to show, and warm its
      // rows so Home isn't empty when the shell appears.
      sl<ActiveSourceCubit>().setSource(repo.sources.first.id);
      sl<HomeCubit>().load();
      await _markOnboarded();
      if (mounted) widget.onDone();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Setup failed — check your connection and try again.';
      });
    }
  }

  Future<void> _skip() async {
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(flex: 2),
              const _Logo(),
              const SizedBox(height: 22),
              Text(
                'Welcome to $kAppName',
                style: AppText.title,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'Anime, movies and TV in one place. To get started we’ll install '
                'the official source catalog — you can add, update or remove '
                'sources any time in Settings → Providers.',
                style: AppText.body.copyWith(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 26),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _bullet(Icons.dns_rounded, 'Multiple streaming sources'),
                  _bullet(Icons.high_quality_rounded, 'Up to 4K / HDR streams'),
                  _bullet(
                    Icons.cloud_download_outlined,
                    'Auto-updating, no app update needed',
                  ),
                ],
              ),
              const Spacer(flex: 3),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: AppText.caption.copyWith(color: AppColors.accent),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 14),
              ],
              if (_busy)
                Column(
                  children: [
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: AppColors.accent,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _status,
                      style: AppText.caption,
                      textAlign: TextAlign.center,
                    ),
                  ],
                )
              else ...[
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _setup,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      _error == null ? 'Get Started' : 'Try Again',
                      style: AppText.button.copyWith(color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: _skip,
                  child: Text(
                    'Skip for now',
                    style: AppText.caption.copyWith(
                      color: AppColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
