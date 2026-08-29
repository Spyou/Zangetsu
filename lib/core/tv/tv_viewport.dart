import 'package:flutter/material.dart';

/// Gives every Flutter TV the same screen-relative coordinate system.
///
/// Android TV devices commonly expose a 960×540 logical surface while tvOS
/// exposes 1920×1080. Without normalization, fixed logical dimensions therefore
/// render at half the physical size on Apple TV. This wrapper keeps a
/// 540-logical-pixel design height and uniformly scales it to the real surface.
class TvViewport extends StatelessWidget {
  const TvViewport({super.key, required this.child});

  static const double designHeight = 540;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        if (!viewport.width.isFinite ||
            !viewport.height.isFinite ||
            viewport.isEmpty) {
          return child;
        }

        final scale = viewport.height / designHeight;
        final logicalSize = Size(viewport.width / scale, designHeight);
        final normalizedMediaQuery = mediaQuery.copyWith(
          size: logicalSize,
          devicePixelRatio: mediaQuery.devicePixelRatio * scale,
          padding: _unscale(mediaQuery.padding, scale),
          viewPadding: _unscale(mediaQuery.viewPadding, scale),
          viewInsets: _unscale(mediaQuery.viewInsets, scale),
          systemGestureInsets: _unscale(mediaQuery.systemGestureInsets, scale),
        );

        // logicalSize has the same aspect ratio as viewport, so BoxFit.fill
        // applies one uniform scale (no stretching). FittedBox also transforms
        // painting, hit testing, focus geometry and semantics together.
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: logicalSize,
              child: MediaQuery(data: normalizedMediaQuery, child: child),
            ),
          ),
        );
      },
    );
  }
}

EdgeInsets _unscale(EdgeInsets value, double scale) => EdgeInsets.fromLTRB(
  value.left / scale,
  value.top / scale,
  value.right / scale,
  value.bottom / scale,
);
