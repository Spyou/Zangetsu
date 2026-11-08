import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

/// Slides the watch page over detail while the player starts loading normally.
class EpisodePlayerRoute extends MaterialPageRoute<void> {
  EpisodePlayerRoute({required super.builder});

  @override
  Duration get transitionDuration =>
      defaultTargetPlatform == TargetPlatform.android
      ? const Duration(milliseconds: 350)
      : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      defaultTargetPlatform == TargetPlatform.android
      ? const Duration(milliseconds: 350)
      : super.reverseTransitionDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Theme.of(context).platform != TargetPlatform.android) {
      return super.buildTransitions(
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return SlideTransition(
      position: animation.drive(
        Tween(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
      ),
      child: child,
    );
  }
}
