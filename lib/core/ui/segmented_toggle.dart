import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Apple-style sliding segmented control.
/// Custom-drawn (no Cupertino dependency) — works identically on Android & iOS.
class SegmentedToggle extends StatelessWidget {
  const SegmentedToggle({
    super.key,
    required this.segments,
    required this.index,
    required this.onChanged,
  });

  final List<String> segments;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final segmentWidth = constraints.maxWidth / segments.length;
        return SizedBox(
          height: 36,
          child: Stack(
            children: [
              // Track background
              DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const SizedBox.expand(),
              ),
              // Animated sliding thumb
              RepaintBoundary(
                child: AnimatedAlign(
                  alignment: Alignment(
                    -1.0 + (2.0 * index + 1.0) / segments.length,
                    0,
                  ),
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  child: SizedBox(
                    width: segmentWidth,
                    height: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          // white @ ~14%
                          color: const Color(0x24FFFFFF),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ),
              // Labels row (tappable)
              Row(
                children: List.generate(segments.length, (i) {
                  final selected = i == index;
                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onChanged(i),
                      child: Center(
                        child: Text(
                          segments[i],
                          style: selected
                              ? AppText.headline.copyWith(
                                  color: AppColors.textPrimary,
                                )
                              : AppText.headline.copyWith(
                                  color: AppColors.textSecondary,
                                  fontWeight: FontWeight.w400,
                                ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ],
          ),
        );
      },
    );
  }
}
