import 'package:flutter/material.dart';

import 'theme_controller.dart';

/// Rebuilds every live route's page when the theme's mutable colours change.
///
/// Screens read [AppColors.bg] / [AppColors.surface] directly during build, so
/// a static colour swap is invisible to routes already on the stack — a pushed
/// screen builds once. Forcing `changedExternalState` on each live route makes
/// the new background appear immediately instead of only after popping back to
/// that screen or restarting the app.
class ThemeRepaintObserver extends NavigatorObserver {
  ThemeRepaintObserver() {
    ThemeController.revision.addListener(_repaint);
  }

  final List<ModalRoute<dynamic>> _routes = [];

  void _repaint() {
    for (final route in List.of(_routes)) {
      route.changedExternalState();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is ModalRoute<dynamic>) _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) _remove(oldRoute);
    if (newRoute is ModalRoute<dynamic> && !_routes.contains(newRoute)) {
      _routes.add(newRoute);
    }
  }

  void _remove(Route<dynamic> route) {
    if (route is ModalRoute<dynamic>) _routes.remove(route);
  }
}
