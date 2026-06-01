import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import 'featured_hero.dart';

/// Fixed hero height — the carousel pins this so the container never resizes
/// between slides and the hero fills it edge-to-edge (Prime-style).
const double kHeroHeight = 540;

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
    this.describe,
  });

  final List<MediaItem> items;
  final bool Function(MediaItem) inList;
  final void Function(MediaItem) onPlay;
  final void Function(MediaItem) onInfo;
  final void Function(MediaItem) onToggleList;

  /// Optional lazily-fetched tagline resolver. Called once per item and the
  /// Future is passed to [FeaturedHero]. Caching is handled by the caller.
  final Future<String?> Function(MediaItem)? describe;

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
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted || !_pc.hasClients) return;
        // Always FORWARD — seamless wrap, never a backward rewind.
        _pc.nextPage(
          duration: const Duration(milliseconds: 750),
          curve: Curves.easeInOutCubic,
        );
      });
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
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pc.dispose();
    super.dispose();
  }

  FeaturedHero _hero(MediaItem it) => FeaturedHero(
    item: it,
    inList: widget.inList(it),
    onPlay: () => widget.onPlay(it),
    onInfo: () => widget.onInfo(it),
    onToggleList: () => widget.onToggleList(it),
    descriptionFuture: widget.describe?.call(it),
  );

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
            // ── Infinite page view ────────────────────────────────────────
            PageView.builder(
              controller: _pc,
              // No itemCount → infinite; modulo maps back to the real slot.
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) => _hero(_pages[i % _count]),
            ),

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
