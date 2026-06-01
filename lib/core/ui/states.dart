import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Loading skeleton grid with a single shared shimmer animation.
/// Uses ONE AnimationController for the whole grid (not per-cell).
/// Disposes its controller correctly.
class SkeletonGrid extends StatefulWidget {
  const SkeletonGrid({
    super.key,
    this.crossAxisCount = 3,
    this.childAspectRatio = 0.62,
  });
  final int crossAxisCount;
  final double childAspectRatio;

  @override
  State<SkeletonGrid> createState() => _SkeletonGridState();
}

class _SkeletonGridState extends State<SkeletonGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final shimmerOpacity = 0.3 + 0.25 * _anim.value;
          return GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: widget.crossAxisCount,
              mainAxisSpacing: 12,
              crossAxisSpacing: 8,
              childAspectRatio: widget.childAspectRatio,
            ),
            itemCount: 9,
            itemBuilder: (context, index) => ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ColoredBox(
                color: AppColors.surface2.withValues(alpha: shimmerOpacity),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Centered empty-state placeholder.
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: AppColors.textTertiary),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center, style: AppText.body),
        ],
      ),
    );
  }
}
