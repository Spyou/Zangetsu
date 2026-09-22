import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'banner_actions.dart';
import 'featured_carousel.dart' show heroHeightFor;
import 'featured_hero.dart' show HeroMeta, heroTopReserve;
import 'image_fade.dart';
import 'native_cover_provider.dart';

/// The "Panels" Home banner: a manga spread.
///
/// One big inked panel for the featured title and two smaller ones beside it,
/// tilted a degree and a half off true with real gutters between them. The two
/// small panels are the NEXT two titles up, so the banner and the row of
/// what-comes-next are the same object — tap one and it takes the big panel.
///
/// Opt-in from Settings → Appearance; the default banner is a different widget.
class FeaturedBannerPanels extends StatefulWidget {
  const FeaturedBannerPanels({
    super.key,
    required this.items,
    required this.inList,
    required this.onPlay,
    required this.onInfo,
    required this.onToggleList,
    this.meta,
    this.reading = false,
  });

  final List<MediaItem> items;
  final bool Function(MediaItem) inList;
  final void Function(MediaItem) onPlay;
  final void Function(MediaItem) onInfo;
  final void Function(MediaItem) onToggleList;
  final Future<HeroMeta?> Function(MediaItem)? meta;
  final bool reading;

  @override
  State<FeaturedBannerPanels> createState() => _FeaturedBannerPanelsState();
}

class _FeaturedBannerPanelsState extends State<FeaturedBannerPanels> {
  /// How far off true the spread sits, in turns. Small on purpose: enough to
  /// read as drawn rather than laid out, not enough to look broken.
  static const double _tilt = -0.004;

  late List<MediaItem> _pages;
  int _i = 0;
  Timer? _timer;

  MediaItem _at(int offset) => _pages[(_i + offset) % _pages.length];
  static String? _art(MediaItem m) => m.banner ?? m.cover;

  @override
  void initState() {
    super.initState();
    _pages = widget.items.take(6).toList();
    _startTimer();
  }

  @override
  void didUpdateWidget(FeaturedBannerPanels old) {
    super.didUpdateWidget(old);
    final next = widget.items.take(6).toList();
    final changed =
        next.length != _pages.length ||
        (next.isNotEmpty &&
            _pages.isNotEmpty &&
            next.first.id != _pages.first.id);
    if (changed) {
      setState(() {
        _pages = next;
        _i = 0;
      });
      _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    if (_pages.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _go(1));
    }
  }

  void _go(int d) {
    if (!mounted || _pages.isEmpty) return;
    setState(() {
      _i = (_i + d) % _pages.length;
      if (_i < 0) _i += _pages.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final height = heroHeightFor(context);
    if (_pages.isEmpty) return SizedBox(height: height);

    final top = heroTopReserve(MediaQuery.paddingOf(context).top);

    return RepaintBoundary(
      child: SizedBox(
        height: height,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -80) {
              _go(1);
              _startTimer();
            } else if (v > 80) {
              _go(-1);
              _startTimer();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: AppColors.bg),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Below the header, not under it. The reserve alone put the
                  // panel's top corner against the download and search icons,
                  // and the tilt lifts that corner higher still.
                  SizedBox(height: top + 6),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(15, 4, 15, 4),
                      child: Transform.rotate(
                        angle: _tilt * 2 * 3.1415926,
                        child: _spread(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _spread() {
    // One small panel per OTHER title, up to two. Two panels showing the same
    // cover — which is what a two-item hero would give — reads as a bug.
    final sides = (_pages.length - 1).clamp(0, 2);
    return Row(
      children: [
        Expanded(flex: 172, child: _mainPanel()),
        if (sides > 0) ...[
          const SizedBox(width: 5),
          Expanded(
            flex: 100,
            child: Column(
              // Stretch, or the panels take their smallest width: nothing
              // inside them asks for a size, so a loose cross-axis constraint
              // collapses them to a hairline.
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _sidePanel(1)),
                if (sides > 1) ...[
                  const SizedBox(height: 5),
                  Expanded(child: _sidePanel(2)),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _mainPanel() {
    final item = _at(0);
    return _InkedPanel(
      leanRight: true,
      onTap: () => widget.onInfo(item),
      child: LayoutBuilder(
        builder: (context, c) => Stack(
          fit: StackFit.expand,
          children: [
            // A phone leaves this panel taller than it is wide, where a 16:9
            // backdrop would be cropped to a strip of someone's chin. Ask the
            // panel which shape it ended up and take the art that fits it.
            _cover(item, wide: c.maxWidth >= c.maxHeight),
            // Ink the bottom so the title logo always has something to sit on.
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xBC000000)],
                    stops: [0.44, 1.0],
                  ),
                ),
              ),
            ),
            // Caption box, top-left, the way a manga panel captions itself.
            // The rank is real — these are the trending items, in order.
            Positioned(
              left: 0,
              top: 10,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.fromLTRB(9, 4, 9, 4),
                child: Text(
                  '#${_i + 1} Trending'.toUpperCase(),
                  style: AppText.caption.copyWith(
                    color: AppColors.bg,
                    fontSize: 8.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 12,
              // Clear of Play (16 + 44), so a long title logo can never run
              // underneath it.
              right: 70,
              bottom: 14,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BannerTitleLogo(
                    item: item,
                    maxHeight: 26,
                    maxWidthFactor: 0.34,
                    align: TextAlign.left,
                    fontSize: 16,
                    onTap: () => widget.onInfo(item),
                  ),
                  const SizedBox(height: 7),
                  // Credit line under the title, the way a cover carries one.
                  BannerMetaLine(
                    metaFuture: widget.meta?.call(item),
                    reading: widget.reading,
                    align: TextAlign.left,
                    compact: true,
                  ),
                ],
              ),
            ),

            // Info and My List share the top corner, stacked; Play sits alone
            // in the bottom one, biggest and on its own, because it is the
            // thing being reached for.
            Positioned(
              top: 10,
              right: 10,
              child: Column(
                children: [
                  BannerCircleButton(
                    icon: Icons.info_outline_rounded,
                    size: 32,
                    onTap: () => widget.onInfo(item),
                    semanticLabel: 'Details',
                  ),
                  const SizedBox(height: 8),
                  BannerCircleButton(
                    icon: widget.inList(item)
                        ? Icons.check_rounded
                        : Icons.add_rounded,
                    active: widget.inList(item),
                    size: 32,
                    onTap: () => widget.onToggleList(item),
                    semanticLabel: widget.inList(item)
                        ? 'Remove from My List'
                        : 'Add to My List',
                  ),
                ],
              ),
            ),
            Positioned(
              // Clear of the angled edge, which leans in ~4.5% at the bottom.
              right: 16,
              bottom: 12,
              child: BannerCircleButton(
                key: const ValueKey('bannerPanelPlay'),
                icon: widget.reading
                    ? Icons.menu_book_rounded
                    : Icons.play_arrow_rounded,
                size: 44,
                filled: true,
                onTap: () => widget.onPlay(item),
                semanticLabel: widget.reading ? 'Read' : 'Play',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidePanel(int offset) {
    final item = _at(offset);
    return _InkedPanel(
      key: ValueKey('bannerSidePanel$offset'),
      leanRight: false,
      onTap: () {
        _go(offset);
        _startTimer();
      },
      child: _cover(item, wide: false),
    );
  }

  Widget _cover(MediaItem item, {required bool wide}) {
    // The big panel is landscape, so it takes the wide art when there is one;
    // the small ones are portrait and always want the poster.
    final url = wide ? _art(item) : (item.cover ?? item.banner);
    if (url == null || url.isEmpty) {
      return ColoredBox(color: AppColors.surface2);
    }
    final mq = MediaQuery.of(context);
    final memW = (mq.size.width * mq.devicePixelRatio * (wide ? 0.7 : 0.35))
        .round();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      // AnimatedSwitcher's default layout stacks its children LOOSE, and a
      // loose-constrained Image shrinks to its own aspect ratio instead of
      // covering — which left a bare strip of panel above the artwork.
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: Image(
        key: ValueKey(url),
        image: ResizeImage(
          nativeCoverProvider(url, item.coverHeaders),
          width: memW,
        ),
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        frameBuilder: imageFadeIn,
        gaplessPlayback: true,
      ),
    );
  }
}

/// One panel: artwork clipped to a slightly trapezoid frame, with the ink line
/// stroked along the same path so the angled edge is drawn, not just cut.
class _InkedPanel extends StatelessWidget {
  const _InkedPanel({
    super.key,
    required this.child,
    required this.leanRight,
    this.onTap,
  });

  final Widget child;

  /// True for the big panel (its right edge leans in), false for the small ones
  /// whose left edge leans out to meet it.
  final bool leanRight;
  final VoidCallback? onTap;

  static Path _path(Size s, bool leanRight) {
    final p = Path();
    if (leanRight) {
      p.moveTo(0, 0);
      p.lineTo(s.width, 0);
      p.lineTo(s.width * 0.955, s.height);
      p.lineTo(0, s.height);
    } else {
      p.moveTo(s.width * 0.055, 0);
      p.lineTo(s.width, 0);
      p.lineTo(s.width, s.height);
      p.lineTo(0, s.height);
    }
    return p..close();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: CustomPaint(
        foregroundPainter: _PanelInk(leanRight),
        child: ClipPath(
          clipper: _PanelClip(leanRight),
          child: ColoredBox(color: AppColors.surface2, child: child),
        ),
      ),
    );
  }
}

class _PanelClip extends CustomClipper<Path> {
  const _PanelClip(this.leanRight);
  final bool leanRight;

  @override
  Path getClip(Size size) => _InkedPanel._path(size, leanRight);

  @override
  bool shouldReclip(_PanelClip old) => old.leanRight != leanRight;
}

class _PanelInk extends CustomPainter {
  const _PanelInk(this.leanRight);
  final bool leanRight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      _InkedPanel._path(size, leanRight),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.88),
    );
  }

  @override
  bool shouldRepaint(_PanelInk old) => old.leanRight != leanRight;
}
