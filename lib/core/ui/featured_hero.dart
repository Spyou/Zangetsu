import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Lightweight metadata shown under the hero title: a few genres + episode
/// count (or year for movies). Lazily fetched, so it never blocks the banner.
class HeroMeta {
  const HeroMeta({this.genres = const [], this.episodeCount = 0, this.year});
  final List<String> genres;
  final int episodeCount;
  final String? year;
}

/// Apple-TV+-style cinematic hero: a rounded inset artwork card floating on a
/// blurred bleed of its own art, with a colour-matched top gradient pulled from
/// the cover's dominant colour, a centred title, an uppercase genres·episodes
/// line, and a clean white Play + glass My-List / Info.
class FeaturedHero extends StatefulWidget {
  const FeaturedHero({
    super.key,
    required this.item,
    required this.inList,
    required this.onPlay,
    required this.onInfo,
    required this.onToggleList,
    this.metaFuture,
    this.parallax = 0,
    this.kenBurns = false,
  });

  final MediaItem item;
  final bool inList;
  final VoidCallback onPlay;
  final VoidCallback onInfo;
  final VoidCallback onToggleList;

  /// Lazily-fetched genres + episode count for this title.
  final Future<HeroMeta?>? metaFuture;

  /// Page-relative offset (-1..1) used to parallax the blurred bleed in the
  /// parallax-slide carousel mode. 0 = no parallax.
  final double parallax;

  /// Slowly zoom the card artwork (Ken-Burns) — used in the cinematic mode.
  final bool kenBurns;

  @override
  State<FeaturedHero> createState() => _FeaturedHeroState();
}

class _FeaturedHeroState extends State<FeaturedHero> {
  // Cache extracted colours so swiping back doesn't recompute the palette.
  static final Map<String, Color> _paletteCache = {};
  Color? _artColor;

  @override
  void initState() {
    super.initState();
    _loadPalette();
  }

  @override
  void didUpdateWidget(FeaturedHero old) {
    super.didUpdateWidget(old);
    if (old.item.cover != widget.item.cover) {
      _artColor = null;
      _loadPalette();
    }
  }

  Future<void> _loadPalette() async {
    final cover = widget.item.cover;
    if (cover == null || cover.isEmpty) return;
    final cached = _paletteCache[cover];
    if (cached != null) {
      setState(() => _artColor = cached);
      return;
    }
    try {
      final pal = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(cover, headers: widget.item.coverHeaders),
        size: const Size(180, 270),
        maximumColorCount: 8,
      );
      final c =
          pal.vibrantColor?.color ??
          pal.dominantColor?.color ??
          pal.darkVibrantColor?.color ??
          pal.mutedColor?.color;
      if (c != null) {
        _paletteCache[cover] = c;
        if (mounted) setState(() => _artColor = c);
      }
    } catch (_) {
      /* keep fallback */
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final cover = item.cover;
    final hasCover = cover != null && cover.isNotEmpty;
    final mq = MediaQuery.of(context);
    final memW = (mq.size.width * mq.devicePixelRatio).round();
    final tint = _artColor ?? AppColors.surface2;

    final provider = hasCover
        ? CachedNetworkImageProvider(cover, headers: item.coverHeaders)
        : null;

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // ── 1. Blurred bleed of the cover (Apple depth) ───────────────────
          // Parallax: the bleed lags behind the card during a slide. Scaled up
          // so the translate never reveals an edge.
          if (provider != null)
            // RepaintBoundary so the (expensive) blur is computed once and
            // cached — not re-run every frame during animations/cross-fades.
            Positioned.fill(
              child: RepaintBoundary(
                child: Transform.translate(
                  offset: Offset(widget.parallax * 48, 0),
                  child: Transform.scale(
                    scale: 1.18,
                    child: ImageFiltered(
                      imageFilter:
                          ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                      child: Image(
                        image: provider,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        // Knock the bleed back so it's a subtle ambiance, not a
                        // bright screen-wide colour wash.
                        color: Colors.black.withValues(alpha: 0.38),
                        colorBlendMode: BlendMode.darken,
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            const ColoredBox(color: AppColors.surface2),

          // Darken the bleed + melt into the page bg at the bottom.
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xCC0B0B0F),
                      Color(0xA60B0B0F),
                      AppColors.bg,
                    ],
                    stops: [0.0, 0.52, 0.92],
                  ),
                ),
              ),
            ),
          ),

          // Colour-matched glow behind the card top — subtle, doesn't reach the
          // status bar or the rows below.
          Positioned(
            top: 40,
            left: 0,
            right: 0,
            height: 230,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.topCenter,
                    radius: 1.0,
                    colors: [
                      tint.withValues(alpha: 0.32),
                      tint.withValues(alpha: 0),
                    ],
                    stops: const [0.0, 0.7],
                  ),
                ),
              ),
            ),
          ),

          // ── 2. Rounded inset artwork card ─────────────────────────────────
          // No glow shadow — it spilled a coloured band BELOW the card. The
          // card already sits on a blurred copy of its own cover, so the edges
          // read softly without one.
          Padding(
            // Full-bleed sides + bottom (rounded top only) so the banner melts
            // straight into the page like the old hero. Top inset clears header.
            padding: const EdgeInsets.fromLTRB(0, 90, 0, 0),
            child: _card(provider, tint, memW),
          ),
        ],
      ),
    );
  }

  Widget _card(ImageProvider? provider, Color tint, int memW) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (provider != null)
            Image(
              image: provider,
              fit: BoxFit.cover,
              // Crop from the top so the poster's own printed title block (and
              // the thin rule above it) is pushed off the bottom and hidden by
              // the gradient — also removes the duplicate "ghosted" title.
              alignment: Alignment.topCenter,
              gaplessPlayback: true,
            )
          else
            const ColoredBox(color: AppColors.surface2),

          // Colour-matched top gradient — pulled from the artwork.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      tint.withValues(alpha: 0.72),
                      tint.withValues(alpha: 0.34),
                      tint.withValues(alpha: 0.08),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.16, 0.34, 0.52],
                  ),
                ),
              ),
            ),
          ),

          // Bottom fade — same technique as the old full-bleed hero: fade to
          // the EXACT page colour (not pure black), so the card bottom becomes
          // the page colour and its edge melts invisibly into the page below.
          const Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x000B0B0F),
                      Color(0xB30B0B0F),
                      AppColors.bg,
                    ],
                    stops: [0.42, 0.72, 1.0],
                  ),
                ),
              ),
            ),
          ),

          // ── Content ───────────────────────────────────────────────────────
          Positioned(
            left: 20,
            right: 20,
            bottom: 44,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: widget.onInfo,
                  child: Text(
                    widget.item.title,
                    textAlign: TextAlign.center,
                    style: AppText.largeTitle.copyWith(
                      fontSize: 30,
                      height: 1.02,
                      letterSpacing: -0.6,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 12),
                // Metadata line (reserve height so the card never jumps).
                SizedBox(height: 18, child: Center(child: _metaLine())),
                const SizedBox(height: 18),
                // Single action row — Play + inline My List (info is on the
                // title tap / long-press), so the overlay stays compact.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _playButton(),
                    const SizedBox(width: 10),
                    _circleBtn(
                      widget.inList ? Icons.check_rounded : Icons.add_rounded,
                      widget.onToggleList,
                      active: widget.inList,
                    ),
                    const SizedBox(width: 10),
                    _circleBtn(Icons.info_outline_rounded, widget.onInfo),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaLine() {
    return FutureBuilder<HeroMeta?>(
      future: widget.metaFuture,
      builder: (context, snap) {
        final m = snap.data;
        if (m == null) return const SizedBox.shrink();
        final parts = <String>[...m.genres.take(3)];
        if (m.episodeCount > 1) {
          parts.add('${m.episodeCount} Episodes');
        } else if (m.year != null && m.year!.isNotEmpty) {
          parts.add(m.year!);
        }
        if (parts.isEmpty) return const SizedBox.shrink();
        return Text(
          parts.join('   ·   ').toUpperCase(),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(
            color: Colors.white.withValues(alpha: 0.92),
            fontWeight: FontWeight.w600,
            letterSpacing: 1.8,
          ),
        );
      },
    );
  }

  Widget _playButton() {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: widget.onPlay,
        child: const SizedBox(
          width: 150,
          height: 50,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.play_arrow_rounded, color: AppColors.bg, size: 24),
              SizedBox(width: 8),
              Text(
                'Play',
                style: TextStyle(
                  fontFamily: 'Inter',
                  color: AppColors.bg,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Inline glass circular action (My List / Info) sitting next to Play.
  Widget _circleBtn(IconData icon, VoidCallback onTap, {bool active = false}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        ),
        child: Icon(
          icon,
          color: active ? AppColors.accent : Colors.white,
          size: 24,
        ),
      ),
    );
  }
}
