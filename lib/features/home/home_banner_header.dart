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
    required this.bannerBuilder,
    required this.headerBuilder,
  });

  final ValueListenable<String> bannerStyle;
  final bool hasHero;
  final Widget Function(String bannerId) bannerBuilder;
  final Widget Function(bool edgeBanner) headerBuilder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: bannerStyle,
    builder: (context, bannerId, _) {
      final header = headerBuilder(bannerId == BannerStyle.edgeId);
      if (!hasHero) {
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
              bannerBuilder(bannerId),
              Positioned(top: 0, left: 0, right: 0, child: header),
            ],
          ),
        ),
      );
    },
  );
}
