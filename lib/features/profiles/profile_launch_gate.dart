import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/profile_shell_scope.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/profile_lock_store.dart';
import '../../core/profiles/profile_lock_remote.dart';
import '../../core/theme/app_colors.dart';
import '../../l10n/l10n.dart';
import 'viewer_profiles_screen.dart';
import '../auth/auth_screens.dart' show LoginScreen;
import '../auth/auth_cubit.dart';

class ProfileLaunchGate extends StatefulWidget {
  const ProfileLaunchGate({super.key, required this.child});

  final Widget child;

  @override
  State<ProfileLaunchGate> createState() => _ProfileLaunchGateState();
}

class _ProfilePickerRoute extends MaterialPageRoute<void> {
  _ProfilePickerRoute({required super.builder});

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);
}

class _ProfileLaunchGateState extends State<ProfileLaunchGate> {
  late bool _deferContent =
      sl<ViewerProfileStore>().askOnLaunch ||
      sl.isRegistered<ProfileLockStore>();
  bool _pickerShown = false;
  Object? _lockError;
  late final ViewerProfileStore _profiles = sl<ViewerProfileStore>();
  late (String, String) _profileContext;
  StreamSubscription<AuthState>? _authSubscription;
  String? _authUserId;
  int _checkGeneration = 0;

  @override
  void initState() {
    super.initState();
    _profileContext = (_profiles.ownerKey, _profiles.activeId);
    _profiles.active.addListener(_onProfileChanged);
    if (sl.isRegistered<AuthCubit>()) {
      final auth = sl<AuthCubit>();
      _authUserId = auth.state.user?.id;
      _authSubscription = auth.stream.listen((state) {
        if (!mounted || state.user?.id == _authUserId) return;
        _authUserId = state.user?.id;
        _checkGeneration++;
        if (sl.isRegistered<ProfileLockStore>()) {
          final locks = sl<ProfileLockStore>();
          locks.clearSwitchApprovals();
          locks.lockEntry(_profiles.activeId);
        }
        setState(() {
          _deferContent = true;
          _lockError = null;
        });
        if (_profiles.isLoadedForCurrentUser && !_pickerShown) {
          _ensureGate(checkLaunchPreference: false);
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureGate();
    });
  }

  void _onProfileChanged() {
    if (!mounted) return;
    final next = (_profiles.ownerKey, _profiles.activeId);
    if (next == _profileContext) return;
    final ownerChanged = next.$1 != _profileContext.$1;
    _profileContext = next;
    _checkGeneration++;
    final locks = sl.isRegistered<ProfileLockStore>()
        ? sl<ProfileLockStore>()
        : null;
    if (ownerChanged) locks?.clearSwitchApprovals();
    final approved = locks?.consumeSwitchApproval(next.$2) ?? false;
    if (!approved) locks?.lockEntry(next.$2);
    if (_pickerShown) return;
    setState(() {
      _deferContent = !approved;
      _lockError = null;
    });
    if (!approved) _ensureGate(checkLaunchPreference: false);
  }

  @override
  void dispose() {
    _profiles.active.removeListener(_onProfileChanged);
    _authSubscription?.cancel();
    super.dispose();
  }

  /// The store restores the last-active profile with no questions asked, so
  /// a locked profile left active resumes straight into unlocked content
  /// when the picker is off. Force the (gated) picker in that case — every
  /// choice out of it passes the PIN/biometric gate.
  Future<void> _ensureGate({bool checkLaunchPreference = true}) async {
    if (_pickerShown) return;
    final generation = ++_checkGeneration;
    setState(() {
      _lockError = null;
      _deferContent = true;
    });
    final store = sl<ViewerProfileStore>();
    if (checkLaunchPreference && store.askOnLaunch) {
      _pickerShown = true;
      if (mounted) _showPicker();
      return;
    }
    try {
      if (sl.isRegistered<ProfileLockStore>()) {
        final locks = sl<ProfileLockStore>();
        final active = store.activeProfile;
        final locked = await locks.isLocked(active.id);
        if (!mounted || generation != _checkGeneration) return;
        if (locked && !locks.isUnlocked(active.id)) {
          _pickerShown = true;
          _showPicker();
          return;
        }
      }
      if (mounted && generation == _checkGeneration) {
        setState(() => _deferContent = false);
      }
    } catch (error) {
      if (mounted && generation == _checkGeneration) {
        setState(() => _lockError = error);
      }
    }
  }

  Future<void> _showPicker() async {
    await Navigator.of(context).push<void>(
      _ProfilePickerRoute(
        builder: (pickerContext) => PopScope(
          canPop: false,
          child: ViewerProfilesScreen(
            selectionOnly: true,
            onSelected: () => _popPicker(pickerContext),
          ),
        ),
      ),
    );
    _pickerShown = false;
    if (mounted && _deferContent) {
      _ensureGate(checkLaunchPreference: false);
    }
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
    return ProfileShellScope(
      deferContent: _deferContent,
      child: _lockError != null
          ? Material(
              color: AppColors.bg,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _lockError is ProfileLockException
                          ? (_lockError as ProfileLockException).message
                          : context.l10n.somethingWentWrong,
                    ),
                    const SizedBox(height: 12),
                    if (_lockError is ProfileLockException &&
                        (_lockError as ProfileLockException).code ==
                            'sign_in_required')
                      FilledButton(
                        onPressed: () async {
                          await Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => const LoginScreen(),
                            ),
                          );
                          if (mounted) _ensureGate();
                        },
                        child: const Text('Sign in'),
                      ),
                    FilledButton(
                      onPressed: _ensureGate,
                      child: Text(context.l10n.retry),
                    ),
                  ],
                ),
              ),
            )
          : widget.child,
    );
  }
}
