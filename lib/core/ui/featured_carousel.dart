import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueListenable, listEquals, visibleForTesting;
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import 'route_observer.dart';
import 'featured_hero.dart';
import 'mobile_hero_art.dart';
import 'poster_palette.dart';

/// Hero height as a share of the screen, so the banner keeps the same
/// proportions everywhere instead of the same pixel count.
///
/// It used to be a flat 540. That is ~62% of a 872dp phone and looks right
/// there, but the same 540 is 84% of a 640dp one — the banner swallowed the
/// whole screen, the dock sat on top of the page dots, and nothing below the
/// hero was reachable without scrolling. Same number, different phone, broken
/// layout. 0.62 is that approved look, expressed as the ratio it always was.
const double kHeroHeightFactor = 0.62;

/// Floor and ceiling. The floor keeps the content block (logo, meta line and
/// buttons — about 230dp with its bottom inset) from crowding the artwork on a
/// very short screen; the ceiling stops a tall tablet getting a hero the size
/// of a poster.
const double kHeroHeightMin = 380;
const double kHeroHeightMax = 560;

/// The hero height for [context]'s screen.
///
/// Reads the screen rather than the incoming constraints on purpose: the
/// carousel is built inside a sliver, where the height constraint is unbounded.
double heroHeightFor(BuildContext context) =>
    (MediaQuery.sizeOf(context).height * kHeroHeightFactor).clamp(
      kHeroHeightMin,
      kHeroHeightMax,
    );

/// Banner transition styles (A/B).
enum HeroTransition {
  /// Cross-fade between banners + Ken-Burns zoom (no horizontal slide).
  cinematic,

  /// Horizontal slide with a parallax blurred background + depth scale.
  parallax,
}

/// Auto-rotating, infinitely-looping hero carousel (up to 6 trending items).
///
/// - Swipeable via [PageView]; auto-advances every 5 s.
/// - **Seamless loop:** the page index lives deep inside a virtualized range and
///   only ever moves FORWARD (`nextPage`), so going from the last item to the
///   first never rewinds backward through every slide.
/// - Page-dot indicator with an animated active dot (maps the virtual index back
///   to the real item via modulo).
/// - Timer + PageController disposed on unmount — no leak.
class FeaturedCarousel extends StatefulWidget {
  const FeaturedCarousel({
    super.key,
    required this.items,
    required this.inList,
    required this.onPlay,
    required this.onInfo,
    required this.onToggleList,
    this.meta,
    this.style = HeroTransition.parallax,
    this.reading = false,
    this.isActive = true,
    this.onArtColor,
    this.backgroundTint,
    this.paletteLoader,
  });

  final List<MediaItem> items;
  final bool Function(MediaItem) inList;
  final void Function(MediaItem) onPlay;
  final void Function(MediaItem) onInfo;
  final void Function(MediaItem) onToggleList;

  /// Optional lazily-fetched metadata resolver (genres + episodes). Called once
  /// per item; the Future is passed to [FeaturedHero]. Caching is the caller's.
  final Future<HeroMeta?> Function(MediaItem)? meta;

  /// Which transition style to use (A = cinematic, B = parallax).
  final HeroTransition style;

  /// Manga/novel mode — forwarded to [FeaturedHero] so the primary action
  /// reads "Read" instead of "Play". Defaults to false; existing callers are
  /// unchanged.
  final bool reading;

  /// Whether the carousel's tab is selected. Route visibility is tracked
  /// separately so a pushed detail page also pauses auto-advance.
  final bool isActive;

  /// Receives the visible slide's artwork colour for Home's background.
  final ValueChanged<Color?>? onArtColor;
  final ValueListenable<Color?>? backgroundTint;

  @visibleForTesting
  final Future<Color?> Function(String, Map<String, String>?)? paletteLoader;

  @override
  State<FeaturedCarousel> createState() => _FeaturedCarouselState();
}

class _FeaturedCarouselState extends State<FeaturedCarousel> with RouteAware {
  // A large base so the PageView can scroll forward "forever" without ever
  // hitting an edge. Picked as a multiple of any realistic item count.
  static const int _virtualBase = 100000;

  late PageController _pc;
  late List<MediaItem> _pages;
  int _index = 0; // virtual page index
  Timer? _timer;
  PageRoute<dynamic>? _route;
  bool _routeIsCurrent = true;

  int get _count => _pages.length;
  bool get _shouldAutoAdvance => widget.isActive && _routeIsCurrent;

  /// Maps the virtual [_index] back to the real item slot.
  int get _realIndex => _count == 0 ? 0 : _index % _count;

  /// A start index that is a multiple of [_count] (so the first real item shows)
  /// yet sits deep in the range, leaving room to advance forward indefinitely.
  int get _startIndex =>
      _count == 0 ? 0 : _virtualBase - (_virtualBase % _count);

  @override
  void initState() {
    super.initState();
    _pages = widget.items.take(6).toList();
    _index = _count > 1 ? _startIndex : 0;
    _pc = PageController(initialPage: _index);
    _startTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncActiveTint();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;

    if (_route != null) appRouteObserver.unsubscribe(this);
    if (route is PageRoute<dynamic>) {
      _route = route;
      _routeIsCurrent = route.isCurrent;
      appRouteObserver.subscribe(this, route);
    } else {
      _route = null;
      _routeIsCurrent = true;
    }
    _syncTimer();
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
    _syncTimer();
  }

  void _syncTimer() {
    if (_shouldAutoAdvance) {
      _startTimer();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = null;
    if (_shouldAutoAdvance && _count > 1) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _advance());
    }
  }

  /// Auto-advance — mode-aware. Cinematic bumps the index (cross-fade); parallax
  /// slides the PageView forward.
  void _advance() {
    if (!mounted || !_shouldAutoAdvance) return;
    if (widget.style == HeroTransition.cinematic) {
      setState(() => _index++);
      _syncActiveTint();
    } else if (_pc.hasClients) {
      _pc.nextPage(
        duration: const Duration(milliseconds: 750),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  @override
  void didUpdateWidget(FeaturedCarousel old) {
    super.didUpdateWidget(old);
    // The items change when the user switches source — rebuild the pages so the
    // banner reflects the new catalog (it used to cache the first source's items).
    final next = widget.items.take(6).toList();
    // Comparing only length + first id misses sources that share a leading
    // title but return different later titles, leaving old-source slides in the
    // carousel until it rotates past them.
    final changed = !listEquals(next, _pages);
    if (changed) {
      setState(() {
        _pages = next;
        _index = _count > 1 ? _startIndex : 0;
      });
      if (_pc.hasClients) _pc.jumpToPage(_index);
      _startTimer();
    }
    if (changed || (old.onArtColor == null && widget.onArtColor != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncActiveTint();
      });
    }
    // Style toggled (A/B) — restart the timer for the new mode and resync the
    // PageController when switching into parallax.
    if (old.style != widget.style) {
      _startTimer();
      if (widget.style == HeroTransition.parallax) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pc.hasClients) _pc.jumpToPage(_index);
        });
      }
    }
    if (old.isActive != widget.isActive) _syncTimer();
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _timer?.cancel();
    _pc.dispose();
    super.dispose();
  }

  Future<void> _syncActiveTint() async {
    if (widget.onArtColor == null) return;
    if (_pages.isEmpty) {
      widget.onArtColor?.call(null);
      return;
    }
    final item = _pages[_realIndex];
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
    final color = await (widget.paletteLoader ?? extractAdaptiveColor)(
      adaptiveSampleUrl(sampleArt, backdrop: usingBackdrop),
      item.coverHeaders,
    );
    if (!mounted || _pages.isEmpty || !identical(_pages[_realIndex], item)) {
      return;
    }
    widget.onArtColor?.call(color);
  }

  FeaturedHero _hero(
    MediaItem it, {
    double parallax = 0,
    bool kenBurns = false,
  }) => FeaturedHero(
    item: it,
    inList: widget.inList(it),
    onPlay: () => widget.onPlay(it),
    onInfo: () => widget.onInfo(it),
    onToggleList: () => widget.onToggleList(it),
    metaFuture: widget.meta?.call(it),
    parallax: parallax,
    kenBurns: kenBurns,
    reading: widget.reading,
    backgroundTint: widget.backgroundTint,
  );

  /// The pager — cinematic cross-fade (A) or parallax slide (B).
  Widget _buildPager() {
    if (widget.style == HeroTransition.cinematic) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v < -80) {
            setState(() => _index++);
            _syncActiveTint();
            _startTimer();
          } else if (v > 80) {
            setState(() => _index--);
            _syncActiveTint();
            _startTimer();
          }
        },
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 650),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: KeyedSubtree(
            key: ValueKey(_realIndex),
            child: _hero(_pages[_realIndex]),
          ),
        ),
      );
    }
    // Parallax slide.
    return PageView.builder(
      controller: _pc,
      onPageChanged: (i) {
        setState(() => _index = i);
        _syncActiveTint();
      },
      itemBuilder: (context, i) => AnimatedBuilder(
        animation: _pc,
        builder: (context, _) {
          var off = 0.0;
          if (_pc.hasClients && _pc.position.haveDimensions) {
            off = (_pc.page ?? _index.toDouble()) - i;
          }
          final scale = (1 - off.abs() * 0.06).clamp(0.94, 1.0);
          return Transform.scale(
            scale: scale,
            child: _hero(_pages[i % _count], parallax: off.clamp(-1.0, 1.0)),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final heroHeight = heroHeightFor(context);

    // Empty state — reserve the height so layout doesn't jump.
    if (_count == 0) return SizedBox(height: heroHeight);

    // Single item — no dots, no timer. Still pinned to the hero height.
    if (_count == 1) {
      return RepaintBoundary(
        child: SizedBox(height: heroHeight, child: _hero(_pages.first)),
      );
    }

    return RepaintBoundary(
      child: SizedBox(
        height: heroHeight,
        child: Stack(
          children: [
            // ── Pager (cinematic cross-fade or parallax slide) ─────────────
            _buildPager(),

            // ── Page dots ─────────────────────────────────────────────────
            Positioned(
              bottom: 18,
              left: 0,
              right: 0,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(_count, (i) {
                    final isActive = i == _realIndex;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        width: isActive ? 20 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: isActive
                              ? AppColors.accent
                              : AppColors.textTertiary.withAlpha(120),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
