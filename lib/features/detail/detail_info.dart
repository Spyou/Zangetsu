// Icon actions and the tab-bar header.
part of 'detail_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// One of the 5 outlined icon actions.
// ─────────────────────────────────────────────────────────────────────────────

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;

  /// Small caption shown under the icon (Netflix-style icon-over-label).
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.textPrimary;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 34,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 24, color: color),
              const SizedBox(height: 6),
              Text(
                label,
                style: AppText.caption.copyWith(
                  color: active ? AppColors.accent : AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pinned tab-bar delegate.
// ─────────────────────────────────────────────────────────────────────────────

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  _TabBarDelegate(this.tabBar, {this.tint});
  final Widget tabBar;
  static const double height = 56;
  final ValueListenable<Color?>? tint;

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // No divider line under the bar — just the left-aligned tabs (Sozo Read).
    final t = tint;
    if (t == null) {
      return Material(color: AppColors.bg, elevation: 0, child: tabBar);
    }
    return ValueListenableBuilder<Color?>(
      valueListenable: t,
      builder: (context, c, _) =>
          Material(color: c ?? AppColors.bg, elevation: 0, child: tabBar),
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarDelegate oldDelegate) =>
      tabBar != oldDelegate.tabBar || tint != oldDelegate.tint;
}

// ─────────────────────────────────────────────────────────────────────────────
// Chip tabs: Overview / Episodes on the left, Comments pushed to the right.
// ─────────────────────────────────────────────────────────────────────────────

class _ChipTabs extends StatelessWidget {
  const _ChipTabs({
    required this.controller,
    required this.labels,
    required this.trailingLabel,
    required this.trailingIcon,
  });

  final TabController controller;

  /// The leading chips, in tab order.
  final List<String> labels;

  /// The last tab, shown on the right edge.
  final String trailingLabel;
  final IconData trailingIcon;

  @override
  Widget build(BuildContext context) {
    // The controller's index changes the instant a tap starts, and again when
    // a swipe passes halfway — so the highlight never waits on the page slide.
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final current = controller.index;
        return LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            // Comments sits on the right edge when there is room. On a very
            // narrow screen the row scrolls sideways instead of overflowing.
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: box.maxWidth - 32),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < labels.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        _TabChip(
                          label: labels[i],
                          selected: current == i,
                          onTap: () => controller.animateTo(i),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(width: 8),
                  _TabChip(
                    label: trailingLabel,
                    icon: trailingIcon,
                    selected: current == labels.length,
                    onTap: () => controller.animateTo(labels.length),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One chip: switches colour at once and squeezes slightly while pressed, so a
/// tap is felt before the page below has finished sliding.
class _TabChip extends StatefulWidget {
  const _TabChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.selected;
    final fg = on ? AppColors.accent : AppColors.textSecondary;
    return Semantics(
      button: true,
      selected: on,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _down ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: on ? AppColors.accentSoft : AppColors.surface2,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 16, color: fg),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.label,
                  style: AppText.caption.copyWith(
                    color: fg,
                    fontSize: 13.5,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The page under the chips: the old page fades out as the new one fades in
// (200ms), instead of sliding sideways like a pager.
// ─────────────────────────────────────────────────────────────────────────────

class _FadePages extends StatefulWidget {
  const _FadePages({required this.controller, required this.children});

  final TabController controller;
  final List<Widget> children;

  @override
  State<_FadePages> createState() => _FadePagesState();
}

class _FadePagesState extends State<_FadePages> {
  /// Pages that have been shown. They stay built (scroll position, loaded
  /// lists) and only fade out, instead of being thrown away and rebuilt.
  final Set<int> _built = {};

  /// A flick this fast, sideways, moves to the neighbouring page.
  static const double _flick = 350;

  void _go(int delta) {
    final c = widget.controller;
    final next = (c.index + delta).clamp(0, c.length - 1);
    if (next != c.index) c.animateTo(next);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final current = widget.controller.index;
        _built.add(current);
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          // Left flick = next page, right flick = previous. A row that scrolls
          // sideways on its own (cast, relations) keeps its own drag.
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v <= -_flick) _go(1);
            if (v >= _flick) _go(-1);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (var i = 0; i < widget.children.length; i++)
                if (_built.contains(i))
                  IgnorePointer(
                    ignoring: i != current,
                    child: ExcludeSemantics(
                      excluding: i != current,
                      child: TickerMode(
                        enabled: i == current,
                        child: AnimatedOpacity(
                          opacity: i == current ? 1 : 0,
                          duration: const Duration(milliseconds: 200),
                          curve: i == current ? Curves.easeOut : Curves.easeIn,
                          child: KeyedSubtree(
                            key: ValueKey('page-$i'),
                            child: widget.children[i],
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}
