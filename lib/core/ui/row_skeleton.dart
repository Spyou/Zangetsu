import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Loading placeholder shaped like a [ContentRow].
///
/// Uses ONE [AnimationController] shared across the whole widget (mirroring
/// the [SkeletonGrid] pattern in states.dart). Disposed in [dispose].
/// The item row is clipped so it never overflows its container.
class RowSkeleton extends StatefulWidget {
  const RowSkeleton({super.key, this.itemWidth = 124, this.itemHeight = 210});

  final double itemWidth;
  final double itemHeight;

  @override
  State<RowSkeleton> createState() => _RowSkeletonState();
}

class _RowSkeletonState extends State<RowSkeleton>
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
          final opacity = 0.3 + 0.25 * _anim.value;
          final shimmerColor = AppColors.surface2.withValues(alpha: opacity);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header strip — mimics the title/overline area
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 120,
                    height: 16,
                    child: ColoredBox(color: shimmerColor),
                  ),
                ),
              ),

              // Horizontal non-scrolling list of skeleton cells — lays out
              // off the right edge without a RenderFlex overflow assertion.
              SizedBox(
                height: widget.itemHeight,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(left: 16),
                  itemCount: 5,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: widget.itemWidth,
                        height: widget.itemHeight,
                        child: ColoredBox(color: shimmerColor),
                      ),
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
