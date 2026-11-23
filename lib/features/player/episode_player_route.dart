import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'in_app_mini_player.dart';

/// Slides the watch page over detail while the player starts loading normally.
class EpisodePlayerRoute extends PageRoute<void>
    with MaterialRouteTransitionMixin<void> {
  EpisodePlayerRoute({
    required WidgetBuilder builder,
    this.nativeHandoff = false,
  }) : _contentKey = GlobalKey(),
       _buildContent = builder;

  EpisodePlayerRoute._(
    this._contentKey,
    this._buildContent,
    this.nativeHandoff,
  );

  final bool nativeHandoff;

  @override
  bool get opaque => !nativeHandoff;

  @override
  bool get maintainState => true;

  final GlobalKey _contentKey;
  final WidgetBuilder _buildContent;
  Widget? _content;
  bool _moved = false;

  @override
  Widget buildContent(BuildContext context) {
    if (_moved) return const SizedBox.shrink();
    return _content ??= KeyedSubtree(
      key: _contentKey,
      child: _buildContent(context),
    );
  }

  ({Widget content, VoidCallback restore})? detachForDock() {
    final nav = navigator;
    final content = _content;
    if (nav == null || content == null || !isCurrent) return null;
    _moved = true;
    nav.removeRoute(this);
    return (
      content: content,
      restore: () {
        if (!nav.mounted) return;
        nav.push(
          EpisodePlayerRoute._(_contentKey, _buildContent, nativeHandoff)
            .._content = content,
        );
      },
    );
  }

  void dock(InAppMiniPlayer Function(Widget, VoidCallback) buildDock) {
    final handoff = detachForDock();
    if (handoff == null) return;
    dockedPlayer.value = buildDock(handoff.content, () {
      handoff.restore();
      dockedPlayer.value = null;
    });
  }

  @override
  Duration get transitionDuration => nativeHandoff
      ? Duration.zero
      : defaultTargetPlatform == TargetPlatform.android
      ? const Duration(milliseconds: 350)
      : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration => nativeHandoff
      ? Duration.zero
      : defaultTargetPlatform == TargetPlatform.android
      ? const Duration(milliseconds: 350)
      : super.reverseTransitionDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (nativeHandoff) return child;
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

PageRoute<void> episodePlayerRoute({
  required WidgetBuilder builder,
  bool nativeHandoff = false,
}) => EpisodePlayerRoute(builder: builder, nativeHandoff: nativeHandoff);
