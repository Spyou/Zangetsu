import 'package:flutter/widgets.dart';

class ProfileShellScope extends InheritedWidget {
  const ProfileShellScope({
    super.key,
    required this.deferContent,
    this.deferTabs = false,
    required super.child,
  });

  final bool deferContent;
  final bool deferTabs;

  static bool shouldDeferContent(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProfileShellScope>()
          ?.deferContent ??
      false;

  static bool shouldDeferTabs(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProfileShellScope>()
          ?.deferTabs ??
      false;

  @override
  bool updateShouldNotify(ProfileShellScope oldWidget) =>
      deferContent != oldWidget.deferContent ||
      deferTabs != oldWidget.deferTabs;
}
