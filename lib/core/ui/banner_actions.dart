import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../di/injector.dart';
import '../metadata/title_logo_service.dart';
import '../models/media_item.dart';

import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'featured_hero.dart' show HeroMeta;

/// The pieces the alternative banner draws over its artwork: the title logo,
/// the metadata line and the round controls.
///
/// Deliberately a separate file rather than something lifted out of
/// [FeaturedHero]: that widget is what every install is looking at right now,
/// and refactoring it to share code here would put the default banner at risk
/// to save a hundred lines. These are smaller and quieter than the hero's —
/// 34px controls, thinner tracking — because the two banners that use them put
/// the artwork, not the buttons, in charge.

/// The TMDB title logo when the title has one, its name in type when it does
/// not. Same lookup the hero uses, so a title that shows a logo there shows the
/// same one here.
class BannerTitleLogo extends StatefulWidget {
  const BannerTitleLogo({
    super.key,
    required this.item,
    this.maxHeight = 44,
    this.maxWidthFactor = 0.72,
    this.align = TextAlign.center,
    this.fontSize = 24,
    this.onTap,
  });

  final MediaItem item;
  final double maxHeight;

  /// Cap as a share of the available width, so a wide logo can't run edge to
  /// edge on a small phone.
  final double maxWidthFactor;
  final TextAlign align;
  final double fontSize;
  final VoidCallback? onTap;

  @override
  State<BannerTitleLogo> createState() => _BannerTitleLogoState();
}

class _BannerTitleLogoState extends State<BannerTitleLogo> {
  String? _url;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BannerTitleLogo old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id) {
      _url = null;
      _load();
    }
  }

  Future<void> _load() async {
    if (!sl.isRegistered<TitleLogoService>()) return;
    try {
      final url = await sl<TitleLogoService>().logoFor(widget.item);
      if (mounted && url != null && url.isNotEmpty) setState(() => _url = url);
    } catch (_) {
      /* stays text */
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final child = _url == null
        ? _text()
        : ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: widget.maxHeight,
              maxWidth: w * widget.maxWidthFactor,
            ),
            child: CachedNetworkImage(
              imageUrl: _url!,
              fit: BoxFit.contain,
              alignment: widget.align == TextAlign.left
                  ? Alignment.centerLeft
                  : Alignment.center,
              fadeInDuration: const Duration(milliseconds: 250),
              errorWidget: (_, _, _) => _text(),
            ),
          );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onTap,
      child: child,
    );
  }

  Widget _text() => Text(
    widget.item.title,
    textAlign: widget.align,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: AppText.largeTitle.copyWith(
      fontSize: widget.fontSize,
      height: 1.04,
      letterSpacing: -0.4,
    ),
  );
}

/// Genres and episode count, thin and wide-tracked. Renders nothing until the
/// metadata resolves, so the banner never jumps to fill a placeholder.
class BannerMetaLine extends StatelessWidget {
  const BannerMetaLine({
    super.key,
    required this.metaFuture,
    this.reading = false,
    this.align = TextAlign.center,
    this.compact = false,
  });

  final Future<HeroMeta?>? metaFuture;
  final bool reading;
  final TextAlign align;

  /// Sitting inside the artwork rather than under it, where there is roughly
  /// half the width: one genre instead of two, and tighter tracking, so the
  /// line ends on a word instead of an ellipsis mid-way through one.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<HeroMeta?>(
      future: metaFuture,
      builder: (context, snap) {
        final m = snap.data;
        if (m == null) return const SizedBox.shrink();
        final parts = <String>[...m.genres.take(compact ? 1 : 2)];
        if (m.episodeCount > 1) {
          parts.add('${m.episodeCount} ${reading ? 'Chapters' : 'Episodes'}');
        } else if (m.year != null && m.year!.isNotEmpty) {
          parts.add(m.year!);
        }
        if (parts.isEmpty) return const SizedBox.shrink();
        return Text(
          parts.join('  ·  ').toUpperCase(),
          textAlign: align,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(
            fontSize: compact ? 8.5 : 9.5,
            color: Colors.white.withValues(alpha: compact ? 0.78 : 0.64),
            fontWeight: FontWeight.w500,
            letterSpacing: compact ? 1.4 : 2.1,
          ),
        );
      },
    );
  }
}

/// One round control — the same glass circle [BannerActions] uses, exposed on
/// its own so a banner can place them individually instead of in a row.
///
/// [filled] is the primary action: solid white, the way Play reads everywhere
/// else in the app.
class BannerCircleButton extends StatelessWidget {
  const BannerCircleButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 34,
    this.filled = false,
    this.active = false,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final bool filled;
  final bool active;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: filled ? Colors.white : Colors.white.withValues(alpha: 0.16),
            shape: BoxShape.circle,
            border: filled
                ? null
                : Border.all(color: Colors.white.withValues(alpha: 0.28)),
            boxShadow: filled
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.32),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            color: filled
                ? AppColors.bg
                : (active ? AppColors.accent : Colors.white),
            size: size * 0.46,
          ),
        ),
      ),
    );
  }
}
