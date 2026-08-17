// Loading skeleton and its shimmer gradient.
part of 'detail_screen.dart';


/// Shimmering placeholder shown while the detail loads — mirrors the real
/// layout (backdrop, title/meta, Play/Download, synopsis, credits) so the
/// screen eases in instead of popping from a blank spinner to a full page.
/// One shared [AnimationController] (same pattern as RowSkeleton/SkeletonGrid).
class _DetailSkeleton extends StatefulWidget {
  const _DetailSkeleton({required this.heroHeight});

  final double heroHeight;

  @override
  State<_DetailSkeleton> createState() => _DetailSkeletonState();
}

class _DetailSkeletonState extends State<_DetailSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    // One continuous forward sweep (not a reversing fade) reads as a real
    // shimmer rather than a dull pulse.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1250),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final base = AppColors.surface2;
    final highlight = Color.lerp(base, Colors.white, 0.14)!;

    Widget box(double w, double h, [double r = 8]) => ClipRRect(
      borderRadius: BorderRadius.circular(r),
      child: SizedBox(
        width: w,
        height: h,
        child: ColoredBox(color: base),
      ),
    );

    // The skeleton shapes, painted in the flat base colour. A moving highlight
    // is swept across them by the ShaderMask below.
    final shapes = SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            height: widget.heroHeight,
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

    // A diagonal highlight band swept across the masked shapes — the classic
    // shimmer sheen, far livelier than a flat opacity pulse.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        child: shapes,
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

/// Translates a gradient horizontally by [t] × width — used to sweep the
/// shimmer highlight across the skeleton.
class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.t);

  final double t;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * t, 0, 0);
}
