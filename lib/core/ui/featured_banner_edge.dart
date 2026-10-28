import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, listEquals, visibleForTesting;
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import 'banner_actions.dart';
import 'featured_carousel.dart' show heroHeightFor;
import 'featured_hero.dart' show HeroMeta;
import 'image_fade.dart';
import 'mobile_hero_art.dart';
import 'native_cover_provider.dart';
import 'poster_palette.dart';
import 'route_observer.dart';

/// Full-bleed Home banner with centered title art and one details action.
class FeaturedBannerEdge extends StatefulWidget {
  const FeaturedBannerEdge({
    super.key,
    required this.items,
    required this.onInfo,
    this.meta,
    this.reading = false,
    this.isActive = true,
    this.onArtColor,
    this.backgroundTint,
    this.paletteLoader,
  });

  final List<MediaItem> items;
  final void Function(MediaItem) onInfo;
  final Future<HeroMeta?> Function(MediaItem)? meta;
  final bool reading;
  final bool isActive;

  /// Reports the visible artwork's dominant colour (null when there is none),
  /// so Home can tint its background. Mirrors [FeaturedCarousel].
  final ValueChanged<Color?>? onArtColor;

  /// Background tint Home is currently painting behind the banner. The bottom
  /// gradient melts into it so the banner and the page never form a seam.
  final ValueListenable<Color?>? backgroundTint;

  @visibleForTesting
  final Future<Color?> Function(String, Map<String, String>?)? paletteLoader;

  @override
  State<FeaturedBannerEdge> createState() => _FeaturedBannerEdgeState();
}

class _FeaturedBannerEdgeState extends State<FeaturedBannerEdge>
    with RouteAware {
  late List<MediaItem> _pages;
  int _index = 0;
  Timer? _timer;
  PageRoute<dynamic>? _route;
  bool _routeIsCurrent = true;

  bool get _isVisible => widget.isActive && _routeIsCurrent;

  /// Current background tint from [widget.backgroundTint] (null → theme bg).
  Color? _bgTint;

  @override
  void initState() {
    super.initState();
    _pages = widget.items.take(6).toList();
    _bgTint = widget.backgroundTint?.value;
    widget.backgroundTint?.addListener(_onBackgroundTint);
    _startTimer();
    _syncTintAfterFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;
    appRouteObserver.unsubscribe(this);
    if (route is PageRoute<dynamic>) {
      _route = route;
      _routeIsCurrent = route.isCurrent;
      appRouteObserver.subscribe(this, route);
    } else {
      _route = null;
      _routeIsCurrent = true;
    }
    _startTimer();
  }

  @override
  void didPush() => _setRouteCurrent(true);

  @override
  void didPopNext() => _setRouteCurrent(true);

  @override
  void didPushNext() => _setRouteCurrent(false);

  @override
  void didPop() => _setRouteCurrent(false);

  void _setRouteCurrent(bool current) {
    if (_routeIsCurrent == current) return;
    _routeIsCurrent = current;
    _startTimer();
    if (_isVisible) _syncTintAfterFrame();
  }

  void _syncTintAfterFrame() {
    // The notifier must not be written during this build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncTint();
    });
  }

  @override
  void didUpdateWidget(FeaturedBannerEdge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backgroundTint != widget.backgroundTint) {
      oldWidget.backgroundTint?.removeListener(_onBackgroundTint);
      _bgTint = widget.backgroundTint?.value;
      widget.backgroundTint?.addListener(_onBackgroundTint);
    }
    final next = widget.items.take(6).toList();
    final changed = !listEquals(next, _pages);
    if (changed) {
      setState(() {
        _pages = next;
        _index = 0;
      });
    }
    if (changed || oldWidget.isActive != widget.isActive) _startTimer();
    if (changed ||
        (!oldWidget.isActive && widget.isActive) ||
        (oldWidget.onArtColor == null && widget.onArtColor != null)) {
      _syncTintAfterFrame();
    }
  }

  void _onBackgroundTint() {
    if (!mounted) return;
    setState(() => _bgTint = widget.backgroundTint?.value);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    widget.backgroundTint?.removeListener(_onBackgroundTint);
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    if (_isVisible && _pages.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _go(1));
    }
  }

  void _go(int delta) {
    if (!mounted || !_isVisible || _pages.isEmpty) return;
    setState(() => _index = (_index + delta + _pages.length) % _pages.length);
    _syncTint();
  }

  /// Extracts the visible item's artwork colour for the caller's background
  /// tint. A slow decode that resolves after the banner moved on is discarded.
  Future<void> _syncTint() async {
    if (!_isVisible || widget.onArtColor == null) return;
    if (_pages.isEmpty) {
      widget.onArtColor?.call(null);
      return;
    }
    final item = _pages[_index];
    final art = mobileHeroArt(item.cover, item.banner);
    if (art == null || art.isEmpty) {
      widget.onArtColor?.call(null);
      return;
    }
    final poster = item.cover?.trim();
    final backdrop = item.banner?.trim();
    final sampleArt = adaptiveArtUrl(poster, backdrop) ?? art;
    final usingBackdrop =
        (poster == null || poster.isEmpty) &&
        backdrop != null &&
        backdrop.isNotEmpty;
    final c = await (widget.paletteLoader ?? extractAdaptiveColor)(
      adaptiveSampleUrl(sampleArt, backdrop: usingBackdrop),
      item.coverHeaders,
    );
    if (!mounted ||
        !_isVisible ||
        _pages.isEmpty ||
        !identical(_pages[_index], item)) {
      return;
    }
    widget.onArtColor?.call(c);
  }

  @override
  Widget build(BuildContext context) {
    final height = heroHeightFor(context);
    if (_pages.isEmpty) return SizedBox(height: height);

    final item = _pages[_index];
    final pageColor = _bgTint ?? AppColors.bg;
    return RepaintBoundary(
      child: SizedBox(
        key: const ValueKey('featuredEdgeBanner'),
        width: double.infinity,
        height: height,
        child: GestureDetector(
          key: const ValueKey('edgeBannerGesture'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: (details) {
            final velocity = details.primaryVelocity ?? 0;
            if (velocity < -80) {
              _go(1);
              _startTimer();
            } else if (velocity > 80) {
              _go(-1);
              _startTimer();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 650),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: KeyedSubtree(
                  key: ValueKey(item.id),
                  child: _artwork(item),
                ),
              ),
              IgnorePointer(
                child: TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: pageColor),
                  duration: adaptiveColourDuration,
                  curve: adaptiveColourCurve,
                  builder: (context, colour, _) => DecoratedBox(
                    key: const ValueKey('edgeBannerScrim'),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          if (widget.backgroundTint == null) ...const [
                            Color(0x66000000),
                            Color(0x33000000),
                            Color(0xCC0B0B0F),
                          ] else ...[
                            (colour ?? AppColors.bg).withValues(alpha: 0.02),
                            (colour ?? AppColors.bg).withValues(alpha: 0.12),
                            (colour ?? AppColors.bg).withValues(alpha: 0.34),
                          ],
                          colour ?? AppColors.bg,
                        ],
                        stops: const [0, 0.28, 0.74, 1],
                      ),
                    ),
                  ),
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 650),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  key: ValueKey('edgeBannerContent-${item.id}'),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 64),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        BannerTitleLogo(
                          item: item,
                          maxHeight: 84,
                          maxWidthFactor: 0.78,
                          fontSize: 30,
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 18,
                          child: Center(
                            child: BannerMetaLine(
                              metaFuture: widget.meta?.call(item),
                              reading: widget.reading,
                            ),
                          ),
                        ),
                        const SizedBox(height: 22),
                        SizedBox(
                          width: 148,
                          height: 48,
                          child: Material(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(24),
                            child: InkWell(
                              key: const ValueKey('edgeBannerViewButton'),
                              onTap: () => widget.onInfo(item),
                              borderRadius: BorderRadius.circular(24),
                              child: Center(
                                child: Text(
                                  'View Details',
                                  style: TextStyle(
                                    color: AppColors.bg,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
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
              ),
              if (_pages.length > 1)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 18,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_pages.length, (index) {
                      final active = index == _index;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                          width: active ? 20 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha: active ? 1 : 0.55,
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _artwork(MediaItem item) {
    final url = mobileHeroArt(item.cover, item.banner);
    final provider = url == null || url.isEmpty
        ? null
        : nativeCoverProvider(url, item.coverHeaders);
    final width =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round();
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF473958), Color(0xFF15151D)],
            ),
          ),
        ),
        if (provider != null)
          Image(
            image: ResizeImage(provider, width: width),
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            frameBuilder: imageFadeIn,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
      ],
    );
  }
}
