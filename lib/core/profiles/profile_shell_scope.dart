import 'package:flutter/widgets.dart';

class ProfileShellScope extends InheritedWidget {
  const ProfileShellScope({
    super.key,
    required this.deferContent,
    required super.child,
  });

  final bool deferContent;

  static bool shouldDeferContent(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ProfileShellScope>()
          ?.deferContent ??
      false;

  @override
  bool updateShouldNotify(ProfileShellScope oldWidget) =>
      deferContent != oldWidget.deferContent;
}
