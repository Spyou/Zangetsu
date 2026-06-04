import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import 'featured_hero.dart';

/// Fixed hero height — the carousel pins this so the container never resizes
/// between slides and the hero fills it edge-to-edge (Prime-style).
const double kHeroHeight = 540;

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

  @override
  State<FeaturedCarousel> createState() => _FeaturedCarouselState();
}

class _FeaturedCarouselState extends State<FeaturedCarousel> {
  // A large base so the PageView can scroll forward "forever" without ever
  // hitting an edge. Picked as a multiple of any realistic item count.
  static const int _virtualBase = 100000;

  late PageController _pc;
  late List<MediaItem> _pages;
  int _index = 0; // virtual page index
  Timer? _timer;

  int get _count => _pages.length;

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
  }

  void _startTimer() {
    _timer?.cancel();
    if (_count > 1) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => _advance());
    }
  }

  /// Auto-advance — mode-aware. Cinematic bumps the index (cross-fade); parallax
  /// slides the PageView forward.
  void _advance() {
    if (!mounted) return;
    if (widget.style == HeroTransition.cinematic) {
      setState(() => _index++);
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
    final changed =
        next.length != _pages.length ||
        (next.isNotEmpty &&
            _pages.isNotEmpty &&
            next.first.id != _pages.first.id);
    if (changed) {
      setState(() {
        _pages = next;
        _index = _count > 1 ? _startIndex : 0;
      });
      if (_pc.hasClients) _pc.jumpToPage(_index);
      _startTimer();
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
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pc.dispose();
    super.dispose();
  }

  FeaturedHero _hero(MediaItem it, {double parallax = 0, bool kenBurns = false}) =>
      FeaturedHero(
        item: it,
        inList: widget.inList(it),
        onPlay: () => widget.onPlay(it),
        onInfo: () => widget.onInfo(it),
        onToggleList: () => widget.onToggleList(it),
        metaFuture: widget.meta?.call(it),
        parallax: parallax,
        kenBurns: kenBurns,
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
            _startTimer();
          } else if (v > 80) {
            setState(() => _index--);
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
      onPageChanged: (i) => setState(() => _index = i),
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
    // Empty state — reserve the height so layout doesn't jump.
    if (_count == 0) return const SizedBox(height: kHeroHeight);

    // Single item — no dots, no timer. Still pinned to the hero height.
    if (_count == 1) {
      return RepaintBoundary(
        child: SizedBox(height: kHeroHeight, child: _hero(_pages.first)),
      );
    }

    return RepaintBoundary(
      child: SizedBox(
        height: kHeroHeight,
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
