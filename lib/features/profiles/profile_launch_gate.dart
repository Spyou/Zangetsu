import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/profile_shell_scope.dart';
import '../../core/profiles/viewer_profile.dart';
import 'viewer_profiles_screen.dart';

class ProfileLaunchGate extends StatefulWidget {
  const ProfileLaunchGate({super.key, required this.child});

  final Widget child;

  @override
  State<ProfileLaunchGate> createState() => _ProfileLaunchGateState();
}

class _ProfileLaunchGateState extends State<ProfileLaunchGate> {
  late bool _deferContent = sl<ViewerProfileStore>().askOnLaunch;

  @override
  void initState() {
    super.initState();
    if (_deferContent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showPicker();
      });
    }
  }

  Future<void> _showPicker() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (pickerContext) => PopScope(
          canPop: false,
          child: ViewerProfilesScreen(
            selectionOnly: true,
            onSelected: () => _popPicker(pickerContext),
          ),
        ),
      ),
    );
    if (mounted) setState(() => _deferContent = false);
  }

  Future<void> _popPicker(BuildContext pickerContext) async {
    // Release the shell BEFORE popping: the avatar Hero's destination (the
    // navbar slot) must be built while the pop transition flies. Flipping
    // after the pop would leave the flight with no landing end.
    if (mounted) setState(() => _deferContent = false);
    await WidgetsBinding.instance.endOfFrame;
    if (pickerContext.mounted) Navigator.of(pickerContext).pop();
  }

  @override
  Widget build(BuildContext context) {
    return ProfileShellScope(deferContent: _deferContent, child: widget.child);
  }
}
