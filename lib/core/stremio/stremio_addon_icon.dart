import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

class StremioAddonIcon extends StatelessWidget {
  const StremioAddonIcon({super.key, this.url, this.size = 32});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(url ?? '');
    final fallback = Icon(
      Icons.extension_outlined,
      color: AppColors.accent,
      size: size * .65,
    );
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: uri != null && ['http', 'https'].contains(uri.scheme)
            ? CachedNetworkImage(
                imageUrl: uri.toString(),
                fit: BoxFit.contain,
                memCacheWidth: 96,
                placeholder: (_, _) => fallback,
                errorWidget: (_, _, _) => fallback,
              )
            : fallback,
      ),
    );
  }
}
