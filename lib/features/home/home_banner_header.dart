import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/ui/banner_style.dart';
import '../../core/ui/featured_carousel.dart' show heroHeightFor;

/// Keeps the selected header layout while banner artwork is still loading.
class HomeBannerHeader extends StatelessWidget {
  const HomeBannerHeader({
    super.key,
    required this.bannerStyle,
    required this.hasHero,
    this.loading = false,
    required this.bannerBuilder,
    required this.headerBuilder,
  });

  final ValueListenable<String> bannerStyle;
  final bool hasHero;
  final bool loading;
  final Widget Function(String bannerId) bannerBuilder;
  final Widget Function(bool edgeBanner) headerBuilder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: bannerStyle,
    builder: (context, bannerId, _) {
      final header = headerBuilder(bannerId == BannerStyle.edgeId);
      if (!hasHero && !loading) {
        return ColoredBox(color: AppColors.bg, child: header);
      }
      final height = heroHeightFor(context);
      // Keep the full banner; only reduce the blank gap before the rows.
      return SizedBox(
        height: height - 10,
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: height,
          maxHeight: height,
          child: Stack(
            children: [
              if (hasHero)
                bannerBuilder(bannerId)
              else
                const Positioned.fill(child: _HeroSkeleton()),
              Positioned(top: 0, left: 0, right: 0, child: header),
            ],
          ),
        ),
      );
    },
  );
}

class _HeroSkeleton extends StatefulWidget {
  const _HeroSkeleton();

  @override
  State<_HeroSkeleton> createState() => _HeroSkeletonState();
}

class _HeroSkeletonState extends State<_HeroSkeleton>
    with SingleTickerProviderStateMixin {
  late final _shimmer = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _shimmer.stop();
    } else if (!_shimmer.isAnimating) {
      _shimmer.repeat();
    }
  }

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = AppColors.surface;
    final highlight = AppColors.surface2;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _shimmer,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 64),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _bar('title', 192, 30, highlight),
                const SizedBox(height: 12),
                _bar('metadata', 112, 14, highlight),
                const SizedBox(height: 22),
                _bar('actions', 148, 48, highlight, radius: 24),
              ],
            ),
          ),
        ),
        builder: (context, controls) {
          final sweep = -3 + 6 * _shimmer.value;
          return Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                key: const ValueKey('hero-skeleton-artwork'),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(sweep - 1, 0),
                    end: Alignment(sweep + 1, 0),
                    colors: [base, highlight, base],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, AppColors.bg],
                    stops: const [0.35, 1],
                  ),
                ),
              ),
              Opacity(
                opacity: 0.7 + 0.3 * (1 - (2 * _shimmer.value - 1).abs()),
                child: controls,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _bar(
    String part,
    double width,
    double height,
    Color color, {
    double radius = 6,
  }) => SizedBox(
    key: ValueKey('hero-skeleton-$part'),
    width: width,
    height: height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
    ),
  );
}
