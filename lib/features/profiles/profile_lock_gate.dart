import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/profile_lock_store.dart';
import '../../core/profiles/profile_lock_remote.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../l10n/l10n.dart';
import '../auth/auth_screens.dart' show LoginScreen;

/// Reuses authentication only for the active profile. Switching back to a
/// locked profile requires biometric/PIN verification again.
Future<bool> ensureProfileUnlocked(
  BuildContext context,
  ViewerProfile profile, {
  ProfileLockStore? locks,
}) async {
  final store =
      locks ??
      (sl.isRegistered<ProfileLockStore>() ? sl<ProfileLockStore>() : null);
  // Widget tests build screens with a minimal DI set — no store, no lock.
  if (store == null) return true;
  try {
    if (!await store.isLocked(profile.id)) return true;
  } catch (error) {
    if (context.mounted) {
      if (error is ProfileLockException && error.code == 'sign_in_required') {
        await Navigator.of(
          context,
        ).push<void>(MaterialPageRoute(builder: (_) => const LoginScreen()));
        return false;
      }
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_lockErrorText(context, error))));
    }
    return false;
  }
  if (store.isUnlocked(profile.id) &&
      sl.isRegistered<ViewerProfileStore>() &&
      sl<ViewerProfileStore>().activeId == profile.id) {
    return true;
  }
  if (!context.mounted) return false;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PinUnlockSheet(profile: profile, locks: store),
  );
  return ok ?? false;
}

String _lockErrorText(BuildContext context, Object error) =>
    error is ProfileLockException
    ? error.message
    : context.l10n.somethingWentWrong;

Future<void> _showRecoveryCode(
  BuildContext context,
  ProfileLockStore locks,
  String profileId,
) async {
  if (!context.mounted) return;
  final code = locks.takeRecoveryCode(profileId);
  if (code == null) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Save your recovery code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Keep this code private. You will need it if you forget this profile’s PIN. Changing the PIN replaces this code.',
            ),
            const SizedBox(height: 16),
            SelectableText(code),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: code)),
            icon: const Icon(Icons.copy_rounded),
            label: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('I saved it'),
          ),
        ],
      ),
    ),
  );
}

/// Set (or change/remove) a profile's PIN. Returns the locked state
/// afterwards, null when the user backed out without changing anything.
Future<bool?> manageProfilePin(
  BuildContext context, {
  required String profileId,
  required String profileName,
  ProfileLockStore? locks,
}) {
  final store =
      locks ??
      (sl.isRegistered<ProfileLockStore>() ? sl<ProfileLockStore>() : null);
  if (store == null) return Future.value();
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PinSetupSheet(
      profileId: profileId,
      profileName: profileName,
      locks: store,
    ),
  );
}

class _SheetShell extends StatelessWidget {
  const _SheetShell({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 12,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textTertiary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(title, style: AppText.headline, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

Widget _pinField({
  required TextEditingController controller,
  required String hint,
  required ValueChanged<String> onSubmitted,
  bool autofocus = false,
  bool numeric = true,
  bool newPin = false,
}) {
  return TextField(
    controller: controller,
    autofocus: autofocus,
    obscureText: true,
    enableSuggestions: false,
    autocorrect: false,
    keyboardType: numeric
        ? TextInputType.number
        : TextInputType.visiblePassword,
    inputFormatters: newPin ? [FilteringTextInputFormatter.digitsOnly] : null,
    maxLength: newPin ? 6 : 32,
    textInputAction: TextInputAction.done,
    onSubmitted: onSubmitted,
    decoration: InputDecoration(
      hintText: hint,
      counterText: '',
      filled: true,
      fillColor: AppColors.surface2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

class _PinUnlockSheet extends StatefulWidget {
  const _PinUnlockSheet({required this.profile, required this.locks});

  final ViewerProfile profile;
  final ProfileLockStore locks;

  @override
  State<_PinUnlockSheet> createState() => _PinUnlockSheetState();
}

class _PinUnlockSheetState extends State<_PinUnlockSheet> {
  final _pin = TextEditingController();
  final _localPin = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _canBio = false;
  bool _needsLegacyPin = false;
  bool _needsNumericPin = false;

  @override
  void initState() {
    super.initState();
    _loadBiometrics();
  }

  Future<void> _loadBiometrics() async {
    try {
      final available = await widget.locks.canUnlockWithBiometrics(
        widget.profile.id,
      );
      if (mounted) {
        setState(() {
          _canBio = available;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _canBio = false);
    }
  }

  @override
  void dispose() {
    _pin.dispose();
    _localPin.dispose();
    super.dispose();
  }

  Future<void> _tryUnlock([String? pin]) async {
    final value = (pin ?? _pin.text).trim();
    if (value.isEmpty || _busy) return;
    setState(() => _busy = true);
    bool ok;
    try {
      ok = await widget.locks.verify(
        widget.profile.id,
        value,
        localPin: _localPin.text.trim(),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _lockErrorText(context, error);
          _needsNumericPin =
              error is ProfileLockException && error.code == 'invalid_pin';
        });
      }
      return;
    }
    if (!mounted) return;
    if (ok) {
      await _showRecoveryCode(context, widget.locks, widget.profile.id);
      if (mounted) Navigator.of(context).pop(true);
      return;
    }
    try {
      final legacy = await widget.locks.needsLegacyPin(widget.profile.id);
      if (!mounted) return;
      setState(() => _needsLegacyPin = legacy);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = context.l10n.wrongPin;
    });
  }

  Future<void> _tryBio() async {
    setState(() => _busy = true);
    bool ok;
    try {
      ok = await widget.locks.authenticateBiometric(
        context.l10n.enterProfilePin(widget.profile.name),
        profileId: widget.profile.id,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _lockErrorText(context, error);
        });
      }
      return;
    }
    if (!mounted) return;
    if (ok) {
      widget.locks.markUnlocked(widget.profile.id);
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _SheetShell(
      title: l10n.unlockProfile,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ProfileAvatarFace(
                profile: widget.profile,
                iconSize: 20,
                photoDiameter: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.enterProfilePin(widget.profile.name),
                  style: AppText.body,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _pinField(
            controller: _pin,
            hint: 'PIN',
            autofocus: !_canBio,
            onSubmitted: (_) => _tryUnlock(),
          ),
          if (_needsLegacyPin) ...[
            const SizedBox(height: 10),
            const Text(
              'If this device used a different PIN before sync, enter that previous PIN too.',
            ),
            const SizedBox(height: 8),
            _pinField(
              controller: _localPin,
              hint: 'Previous PIN on this device',
              numeric: false,
              onSubmitted: (_) => _tryUnlock(),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
          ],
          if (_needsNumericPin)
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final changed = await manageProfilePin(
                        context,
                        profileId: widget.profile.id,
                        profileName: widget.profile.name,
                        locks: widget.locks,
                      );
                      if (context.mounted &&
                          changed == true &&
                          widget.locks.isUnlocked(widget.profile.id)) {
                        Navigator.of(context).pop(true);
                      }
                    },
              child: const Text('Set a numeric PIN'),
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              if (_canBio)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _tryBio,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: Text(l10n.useFingerprint),
                  ),
                ),
              if (_canBio) const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : () => _tryUnlock(),
                  child: _busy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(l10n.unlockProfile),
                ),
              ),
            ],
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    final recovered = await showModalBottomSheet<bool>(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: AppColors.surface,
                      builder: (_) => _PinRecoverySheet(
                        profile: widget.profile,
                        locks: widget.locks,
                      ),
                    );
                    if (recovered == true && context.mounted) {
                      Navigator.of(context).pop(true);
                    }
                  },
            child: const Text('Forgot PIN?'),
          ),
        ],
      ),
    );
  }
}

class _PinSetupSheet extends StatefulWidget {
  const _PinSetupSheet({
    required this.profileId,
    required this.profileName,
    required this.locks,
  });

  final String profileId;
  final String profileName;
  final ProfileLockStore locks;

  @override
  State<_PinSetupSheet> createState() => _PinSetupSheetState();
}

class _PinSetupSheetState extends State<_PinSetupSheet> {
  final _current = TextEditingController();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  Object? _loadError;
  bool _busy = false;
  bool? _hasLock;
  bool _fingerprint = false;
  bool _editingPin = false;
  bool _supportsBiometrics = false;

  @override
  void initState() {
    super.initState();
    _loadLock();
  }

  Future<void> _loadLock() async {
    setState(() {
      _hasLock = null;
      _loadError = null;
    });
    try {
      final locked = await widget.locks.isLocked(widget.profileId);
      final available = await widget.locks.canUseBiometrics;
      final enabled =
          locked && await widget.locks.biometricEnabled(widget.profileId);
      if (mounted) {
        setState(() {
          _hasLock = locked;
          _supportsBiometrics = available;
          _fingerprint = enabled;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  @override
  void dispose() {
    _current.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _failure(Object error) {
    if (mounted) {
      setState(() {
        _busy = false;
        _error = _lockErrorText(context, error);
      });
    }
  }

  Future<void> _save() async {
    if (_busy || _hasLock == null) return;
    final pin = _pin.text.trim();
    if (!ProfileLockStore.isValidNewPin(pin)) {
      setState(() => _error = 'Choose a 4 or 6 digit PIN.');
      return;
    }
    if (pin != _confirm.text.trim()) {
      setState(() => _error = context.l10n.pinMismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await widget.locks.setPin(
        widget.profileId,
        pin,
        currentPin: _current.text.trim(),
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _busy = false;
          _error = 'Choose a 4 or 6 digit PIN.';
        });
        return;
      }
      await _showRecoveryCode(context, widget.locks, widget.profileId);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      _failure(error);
    }
  }

  Future<bool> _askPin({
    required String title,
    required String button,
    required Future<void> Function(String) confirm,
  }) async {
    return await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          isDismissible: false,
          enableDrag: false,
          backgroundColor: AppColors.surface,
          builder: (_) => _PinConfirmationSheet(
            title: title,
            button: button,
            confirm: confirm,
          ),
        ) ??
        false;
  }

  Future<void> _remove() async {
    if (_busy || _hasLock != true) return;
    final removed = await _askPin(
      title: 'Remove profile lock',
      button: 'Remove lock',
      confirm: (pin) async {
        if (!await widget.locks.verify(widget.profileId, pin)) {
          throw const ProfileLockException('verification_failed');
        }
        await widget.locks.clear(widget.profileId, pin: pin);
      },
    );
    if (mounted && removed) Navigator.of(context).pop(false);
  }

  Future<void> _toggleFingerprint(bool enabled) async {
    if (_busy || _hasLock != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final changed =
          !enabled ||
          await _askPin(
            title: 'Enable fingerprint',
            button: 'Enable fingerprint',
            confirm: (pin) => widget.locks.setBiometricEnabled(
              widget.profileId,
              true,
              pin: pin,
            ),
          );
      if (!enabled) {
        await widget.locks.setBiometricEnabled(widget.profileId, false);
      }
      if (!mounted) return;
      await _showRecoveryCode(context, widget.locks, widget.profileId);
      if (mounted) {
        setState(() {
          if (changed) _fingerprint = enabled;
          _busy = false;
        });
      }
    } catch (error) {
      _failure(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _SheetShell(
      title: _hasLock == true
          ? (_editingPin ? l10n.changeProfilePin : l10n.profileLock)
          : l10n.setProfilePin,
      child: _loadError != null
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_lockErrorText(context, _loadError!)),
                const SizedBox(height: 12),
                FilledButton(onPressed: _loadLock, child: Text(l10n.retry)),
              ],
            )
          : _hasLock == null
          ? Text(l10n.loading, textAlign: TextAlign.center)
          : _hasLock == true && !_editingPin
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  key: const ValueKey('profile-change-pin'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.pin_outlined),
                  title: Text(l10n.changeProfilePin),
                  subtitle: const Text('Choose a new 4 or 6 digit PIN'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _busy
                      ? null
                      : () => setState(() {
                          _editingPin = true;
                          _error = null;
                        }),
                ),
                if (_supportsBiometrics)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use fingerprint on this phone'),
                    subtitle: const Text(
                      'Your PIN still works. Other devices keep their own setting.',
                    ),
                    value: _fingerprint,
                    onChanged: _busy ? null : _toggleFingerprint,
                  ),
                if (_error != null)
                  Text(
                    _error!,
                    style: AppText.caption.copyWith(color: AppColors.accent),
                  ),
                TextButton(
                  onPressed: _busy ? null : _remove,
                  child: Text(l10n.removeProfileLock),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_hasLock == true) ...[
                  _pinField(
                    controller: _current,
                    hint: 'Current PIN',
                    onSubmitted: (_) {},
                  ),
                  const SizedBox(height: 10),
                ],
                _pinField(
                  controller: _pin,
                  hint: 'New PIN (4 or 6 digits)',
                  newPin: true,
                  autofocus: _hasLock != true,
                  onSubmitted: (_) {},
                ),
                const SizedBox(height: 10),
                _pinField(
                  controller: _confirm,
                  hint: l10n.confirmProfilePin,
                  newPin: true,
                  onSubmitted: (_) => _save(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: AppText.caption.copyWith(color: AppColors.accent),
                  ),
                ],
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(
                    _busy
                        ? l10n.loading
                        : _hasLock == true
                        ? l10n.changeProfilePin
                        : l10n.setProfilePin,
                  ),
                ),
                if (_hasLock == true)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _editingPin = false;
                            _error = null;
                            _current.clear();
                            _pin.clear();
                            _confirm.clear();
                          }),
                    child: const Text('Back'),
                  ),
              ],
            ),
    );
  }
}

class _PinConfirmationSheet extends StatefulWidget {
  const _PinConfirmationSheet({
    required this.title,
    required this.button,
    required this.confirm,
  });
  final String title;
  final String button;
  final Future<void> Function(String) confirm;
  @override
  State<_PinConfirmationSheet> createState() => _PinConfirmationSheetState();
}

class _PinConfirmationSheetState extends State<_PinConfirmationSheet> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_busy || _pin.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.confirm(_pin.text.trim());
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _lockErrorText(context, error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: _SheetShell(
      title: widget.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Enter this profile’s current PIN to continue.'),
          const SizedBox(height: 12),
          _pinField(
            controller: _pin,
            hint: 'Current PIN',
            autofocus: true,
            onSubmitted: (_) => _confirm(),
          ),
          if (_error != null)
            Text(
              _error!,
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _busy ? null : _confirm,
            child: Text(_busy ? context.l10n.loading : widget.button),
          ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  );
}

class _PinRecoverySheet extends StatefulWidget {
  const _PinRecoverySheet({required this.profile, required this.locks});
  final ViewerProfile profile;
  final ProfileLockStore locks;
  @override
  State<_PinRecoverySheet> createState() => _PinRecoverySheetState();
}

class _PinRecoverySheetState extends State<_PinRecoverySheet> {
  final _code = TextEditingController();
  final _localPin = TextEditingController();
  bool _needsLegacyPin = false;

  @override
  void initState() {
    super.initState();
    widget.locks
        .needsLegacyPin(widget.profile.id)
        .then((value) {
          if (mounted) setState(() => _needsLegacyPin = value);
        })
        .catchError((Object _) {});
  }

  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _localPin.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _recover() async {
    if (_busy) return;
    if (!ProfileLockStore.isValidNewPin(_pin.text.trim())) {
      setState(() => _error = 'Choose a 4 or 6 digit PIN.');
      return;
    }
    if (_pin.text.trim() != _confirm.text.trim()) {
      setState(() => _error = context.l10n.pinMismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ok = await widget.locks.recover(
        widget.profile.id,
        _code.text.trim(),
        _pin.text.trim(),
        localPin: _localPin.text.trim(),
      );
      if (!mounted) return;
      if (!ok) throw const ProfileLockException('verification_failed');
      await _showRecoveryCode(context, widget.locks, widget.profile.id);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _lockErrorText(context, error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => _SheetShell(
    title: 'Recover profile PIN',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Use the private recovery code saved when this profile’s PIN was set.',
        ),
        const SizedBox(height: 12),
        _pinField(
          controller: _code,
          hint: 'Recovery code',
          numeric: false,
          autofocus: true,
          onSubmitted: (_) {},
        ),
        if (_needsLegacyPin) ...[
          const SizedBox(height: 10),
          _pinField(
            controller: _localPin,
            hint: 'Previous PIN on this device',
            onSubmitted: (_) {},
          ),
        ],
        const SizedBox(height: 10),
        _pinField(
          controller: _pin,
          hint: 'New PIN (4 or 6 digits)',
          newPin: true,
          onSubmitted: (_) {},
        ),
        const SizedBox(height: 10),
        _pinField(
          controller: _confirm,
          hint: context.l10n.confirmProfilePin,
          newPin: true,
          onSubmitted: (_) => _recover(),
        ),
        if (_error != null)
          Text(
            _error!,
            style: AppText.caption.copyWith(color: AppColors.accent),
          ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _busy ? null : _recover,
          child: Text(_busy ? context.l10n.loading : 'Reset PIN'),
        ),
      ],
    ),
  );
}
