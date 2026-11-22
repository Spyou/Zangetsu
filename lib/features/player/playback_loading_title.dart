import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

Map<String, String>? playbackArtworkHeaders(
  String? artwork,
  String? cover,
  Map<String, String>? headers,
) {
  final image = Uri.tryParse(artwork ?? '');
  final original = Uri.tryParse(cover ?? '');
  if (image == null || original == null || image.host.isEmpty) return null;
  if (image.scheme != 'http' && image.scheme != 'https') return null;
  return image.scheme == original.scheme &&
          image.host == original.host &&
          image.port == original.port
      ? headers
      : null;
}

class PlaybackLoadingTitle extends StatelessWidget {
  const PlaybackLoadingTitle({
    super.key,
    required this.title,
    required this.status,
    this.logo,
  });

  final String title;
  final String status;
  final String? logo;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      title,
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 22,
        fontWeight: FontWeight.bold,
      ),
    );
    Widget pulse(Widget child) => MediaQuery.disableAnimationsOf(context)
        ? child
        : _StartupTitlePulse(child: child);

    final titleWidget = logo?.trim().isNotEmpty == true
        ? CachedNetworkImage(
            key: ValueKey(logo),
            imageUrl: logo!,
            height: 44,
            fit: BoxFit.contain,
            memCacheWidth: 720,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            placeholder: (_, _) => pulse(text),
            errorWidget: (_, _, _) => pulse(text),
            imageBuilder: (_, provider) => pulse(
              Image(
                image: provider,
                height: 44,
                fit: BoxFit.contain,
                semanticLabel: title,
              ),
            ),
          )
        : pulse(text);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 44),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title.isNotEmpty || logo?.trim().isNotEmpty == true)
              titleWidget,
            const SizedBox(height: 8),
            Text(
              status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _StartupTitlePulse extends StatefulWidget {
  const _StartupTitlePulse({required this.child});

  final Widget child;

  @override
  State<_StartupTitlePulse> createState() => _StartupTitlePulseState();
}

class _StartupTitlePulseState extends State<_StartupTitlePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      child: widget.child,
      builder: (context, child) => Transform.scale(
        key: const ValueKey('startup-title-motion'),
        scale: 1 + 0.035 * Curves.easeInOut.transform(_pulse.value),
        child: child,
      ),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }
}
