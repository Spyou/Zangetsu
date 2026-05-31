import 'dart:async';

import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../theme/app_colors.dart';
import 'featured_hero.dart';

/// Auto-rotating hero carousel showing up to 6 trending items.
///
/// - Swipeable via [PageView].
/// - Auto-advances every 5 seconds.
/// - Page dot indicator with animated active dot.
/// - Timer and PageController are disposed on unmount — no leak.
/// - Fixed height 450 px matches [FeaturedHero]'s deterministic natural height.
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

  /// Optional lazily-fetched description resolver. Called once per item and
  /// the Future is passed to [FeaturedHero] so it can populate the 3-line
  /// description box. Caching is handled by the caller (HomeScreen).
  final Future<String?> Function(MediaItem)? describe;

  @override
  State<FeaturedCarousel> createState() => _FeaturedCarouselState();
}

class _FeaturedCarouselState extends State<FeaturedCarousel> {
  late final PageController _pc;
  late final List<MediaItem> _pages;
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _pages = widget.items.take(6).toList();
    _pc = PageController();

    // Only start auto-advance when there is more than one item.
    if (_pages.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted) return;
        if (!_pc.hasClients) return;
        final next = (_index + 1) % _pages.length;
        _pc.animateToPage(
          next,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Empty state — reserve the same 450 px so layout doesn't jump.
    if (_pages.isEmpty) return const SizedBox(height: 450);

    // Single item — no dots, no timer needed. Still wrapped to 450 px.
    if (_pages.length == 1) {
      final it = _pages.first;
      return RepaintBoundary(
        child: SizedBox(
          height: 450,
          child: FeaturedHero(
            item: it,
            inList: widget.inList(it),
            onPlay: () => widget.onPlay(it),
            onInfo: () => widget.onInfo(it),
            onToggleList: () => widget.onToggleList(it),
            descriptionFuture: widget.describe?.call(it),
          ),
        ),
      );
    }

    return RepaintBoundary(
      child: SizedBox(
        height: 450,
        child: Stack(
          children: [
            // ── Page view ─────────────────────────────────────────────────
            PageView.builder(
              controller: _pc,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final it = _pages[i];
                return FeaturedHero(
                  item: it,
                  inList: widget.inList(it),
                  onPlay: () => widget.onPlay(it),
                  onInfo: () => widget.onInfo(it),
                  onToggleList: () => widget.onToggleList(it),
                  descriptionFuture: widget.describe?.call(it),
                );
              },
            ),

            // ── Page dots ─────────────────────────────────────────────────
            Positioned(
              bottom: 8,
              left: 0,
              right: 0,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(_pages.length, (i) {
                    final isActive = i == _index;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: isActive ? 18 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: isActive
                              ? AppColors.accent
                              : AppColors.textTertiary.withAlpha(128),
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
