import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

class BrandLoader extends StatefulWidget {
  const BrandLoader({super.key, this.label});
  final String? label;
  @override
  State<BrandLoader> createState() => _BrandLoaderState();
}

class _BrandLoaderState extends State<BrandLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 120,
            height: 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: Stack(
                children: [
                  const ColoredBox(
                    color: AppColors.surface2,
                    child: SizedBox.expand(),
                  ),
                  AnimatedBuilder(
                    animation: _c,
                    builder: (context, _) => Align(
                      alignment: Alignment(-1.0 + 2.0 * _c.value, 0),
                      child: const FractionallySizedBox(
                        widthFactor: 0.4,
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Color(0x00FF4D57),
                                AppColors.accent,
                                Color(0x00FF4D57),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.label != null) ...[
            const SizedBox(height: 14),
            Text(widget.label!, style: AppText.body),
          ],
        ],
      ),
    );
  }
}
