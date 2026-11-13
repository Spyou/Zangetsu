// Loading skeleton and its shimmer gradient.
part of 'detail_screen.dart';

/// Shimmering placeholder shown while the detail loads — mirrors the real
/// layout (backdrop, title/meta, Play/Download, synopsis, credits) so the
/// screen eases in instead of popping from a blank spinner to a full page.
/// One shared [AnimationController] (same pattern as RowSkeleton/SkeletonGrid).
/// A flat placeholder shape in the skeleton base colour. Shared by every
/// skeleton here so they all read as the same material.
Widget _bone(double w, double h, [double r = 8]) => ClipRRect(
  borderRadius: BorderRadius.circular(r),
  child: SizedBox(
    width: w,
    height: h,
    child: ColoredBox(color: AppColors.surface2),
  ),
);

/// Sweeps the shimmer sheen across whatever flat shapes it wraps. Owns the
/// controller, so a new skeleton is a tree of [_bone]s inside this rather
/// than another copy of the animation plumbing.
class _Shimmer extends StatefulWidget {
  const _Shimmer({required this.child});

  final Widget child;

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Animation<double>? _routeAnim;

  @override
  void initState() {
    super.initState();
    // One continuous forward sweep (not a reversing fade) reads as a real
    // shimmer rather than a dull pulse.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeAnim = ModalRoute.of(context)?.animation;
    if (identical(routeAnim, _routeAnim)) return;
    _routeAnim?.removeStatusListener(_syncToRoute);
    _routeAnim = routeAnim;
    _routeAnim?.addStatusListener(_syncToRoute);
    _syncToRoute(_routeAnim?.status ?? AnimationStatus.completed);
  }

  /// Only sweep the sheen while the page is settled. The [ShaderMask] repaints
  /// the whole skeleton, so letting it run underneath the detail route's
  /// slide transition stacked two full-screen operations and dropped frames
  /// on low-end phones — the same collision the slide-only route fixed.
  void _syncToRoute(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      if (!_ctrl.isAnimating) _ctrl.repeat();
    } else {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _routeAnim?.removeStatusListener(_syncToRoute);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = AppColors.surface2;
    final highlight = Color.lerp(base, Colors.white, 0.14)!;
    // A diagonal highlight band swept across the masked shapes — the classic
    // shimmer sheen, far livelier than a flat opacity pulse.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        child: widget.child,
        builder: (context, child) {
          final t =
              _ctrl.value * 3 - 1; // -1 → 2 : band enters left, exits right
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [base, highlight, base],
              stops: const [0.32, 0.5, 0.68],
              transform: _SlideGradient(t),
            ).createShader(bounds),
            child: child,
          );
        },
      ),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton({required this.heroHeight});

  final double heroHeight;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final base = AppColors.surface2;
    const box = _bone;

    // The skeleton shapes, painted in the flat base colour. A moving highlight
    // is swept across them by the ShaderMask below.
    final shapes = SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            height: heroHeight,
            child: ColoredBox(color: base),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                box(width * 0.66, 26), // title
                const SizedBox(height: 12),
                box(width * 0.42, 14), // meta line
                const SizedBox(height: 20),
                box(double.infinity, 50, 14), // Play
                const SizedBox(height: 10),
                box(double.infinity, 50, 14), // Download
                const SizedBox(height: 22),
                box(double.infinity, 12), // synopsis line 1
                const SizedBox(height: 9),
                box(double.infinity, 12), // synopsis line 2
                const SizedBox(height: 9),
                box(width * 0.55, 12), // synopsis line 3
                const SizedBox(height: 22),
                box(width * 0.5, 13), // starring
                const SizedBox(height: 12),
                box(width * 0.4, 13), // creators / genres
              ],
            ),
          ),
        ],
      ),
    );

    return _Shimmer(child: shapes);
  }
}

/// Lightweight first frame: artwork and title are known from the tapped row,
/// so the screen feels immediate while the complete detail tree waits for the
/// spring transition to settle.
class _DetailOpeningPreview extends StatelessWidget {
  const _DetailOpeningPreview({required this.item, required this.heroHeight});

  final MediaItem item;
  final double heroHeight;

  @override
  Widget build(BuildContext context) {
    final coverUrl =
        mobileHeroArt(
          item.cover,
          item.banner ?? item.landscapePoster,
          sourceId: item.sourceId,
        ) ??
        '';
    final topInset = MediaQuery.paddingOf(context).top;
    final titleStyle = AppText.largeTitle.copyWith(fontSize: 28);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          CustomScrollView(
            physics: const NeverScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(
                  // Exactly the real hero height: SliverAppBar's expandedHeight
                  // already includes the status-bar area, so adding topInset
                  // here made the preview taller and the swap visibly jumped.
                  height: heroHeight,
                  child: RepaintBoundary(
                    child: _Hero(
                      coverUrl: coverUrl,
                      coverHeaders: item.coverHeaders,
                      hasCover: coverUrl.isNotEmpty,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        style: titleStyle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if ((item.quality?.trim().isNotEmpty ?? false) ||
                          item.isAdult) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            if (item.quality?.trim().isNotEmpty ?? false)
                              _MetaBadge(item.quality!.trim().toUpperCase()),
                            if (item.isAdult) const _MetaBadge('18+'),
                          ],
                        ),
                      ],
                      const SizedBox(height: 18),
                      _bone(double.infinity, 48, 14),
                      const SizedBox(height: 12),
                      _bone(double.infinity, 48, 14),
                      const SizedBox(height: 22),
                      _bone(double.infinity, 12),
                      const SizedBox(height: 9),
                      _bone(double.infinity, 12),
                      const SizedBox(height: 9),
                      _bone(180, 12),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            // Same widget and spot as the SliverAppBar's automatic leading
            // (56-wide leading box, icon centred): a different style or a few
            // pixels off reads as a pop on the preview → body swap.
            top: topInset + 4,
            left: 14,
            child: const _DetailBackButton(),
          ),
        ],
      ),
    );
  }
}

/// Placeholder episode rows for the Episodes tab while the matched source's
/// list is still being fetched — see [DetailState.episodesLoading]. The
/// screen now paints before that fetch finishes, and an empty list there
/// would otherwise read as "this source has nothing".
class _EpisodeListSkeleton extends StatelessWidget {
  const _EpisodeListSkeleton();

  @override
  Widget build(BuildContext context) => _Shimmer(
    child: ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 6,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      // Mirrors the real episode row — 116×66 thumb, title line, meta line —
      // so the list settles in place instead of jumping when it arrives.
      itemBuilder: (context, _) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _bone(116, 66, 10),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 6),
                _bone(double.infinity, 13),
                const SizedBox(height: 9),
                _bone(120, 11),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Translates a gradient horizontally by [t] × width — used to sweep the
/// shimmer highlight across the skeleton.
class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.t);

  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * t, 0, 0);
}
