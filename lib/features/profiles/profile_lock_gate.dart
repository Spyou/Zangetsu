import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/profile_lock_store.dart';
import '../../core/profiles/profile_lock_remote.dart';
import '../../core/profiles/viewer_profile.dart';
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
  return await _showPinDialog(
        context,
        builder: (_) => _PinUnlockSheet(profile: profile, locks: store),
      ) ??
      false;
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
  bool openChange = false,
}) {
  final store =
      locks ??
      (sl.isRegistered<ProfileLockStore>() ? sl<ProfileLockStore>() : null);
  if (store == null) return Future.value();
  return _showPinDialog(
    context,
    builder: (_) => _PinSetupSheet(
      profileId: profileId,
      profileName: profileName,
      locks: store,
      openChange: openChange,
    ),
  );
}

Future<bool?> _showPinDialog(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final navigator = Navigator.of(context);
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final route = RawDialogRoute<bool>(
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
    transitionDuration: reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => themes.wrap(
      SafeArea(
        child: _PinDialog(child: Builder(builder: builder)),
      ),
    ),
    transitionBuilder: (_, animation, _, child) {
      final eased = animation.drive(CurveTween(curve: Curves.easeInOutCubic));
      return FadeTransition(
        key: const ValueKey('profile-pin-dialog-fade'),
        opacity: eased,
        child: SlideTransition(
          position: eased.drive(
            Tween(begin: const Offset(0, 0.035), end: Offset.zero),
          ),
          child: child,
        ),
      );
    },
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

class _PinDialog extends StatelessWidget {
  const _PinDialog({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    elevation: 0,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 304),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Material(
            color: const Color(0x65101115),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: const BorderSide(color: Color(0x26FFFFFF)),
            ),
            child: AnimatedSize(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

class _SheetShell extends StatelessWidget {
  const _SheetShell({
    required this.title,
    required this.child,
    this.dialog = false,
  });

  final String title;
  final Widget child;
  final bool dialog;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.only(
            left: dialog ? 16 : 20,
            right: dialog ? 16 : 20,
            top: dialog ? 18 : 12,
            bottom:
                MediaQuery.viewInsetsOf(context).bottom + (dialog ? 12 : 20),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!dialog)
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
              Text(
                title,
                style: dialog
                    ? AppText.headline.copyWith(fontSize: 22)
                    : AppText.headline,
                textAlign: TextAlign.center,
              ),
              SizedBox(height: dialog ? 10 : 16),
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

class _ProfilePinKeypad extends StatelessWidget {
  const _ProfilePinKeypad({
    required this.controller,
    required this.length,
    required this.enabled,
    this.onComplete,
    this.unknownLength = false,
  });

  final TextEditingController controller;
  final int length;
  final bool enabled;
  final VoidCallback? onComplete;
  final bool unknownLength;

  void _press(String key) {
    final pin = controller.text;
    if (key == '⌫') {
      controller.text = pin.substring(0, pin.length - 1);
    } else {
      controller.text = pin + key;
      if (controller.text.length == length) onComplete?.call();
    }
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) => Column(
      children: [
        Semantics(
          label: '${value.text.length} digits entered',
          child: ExcludeSemantics(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (
                  var i = 0;
                  i < (unknownLength && value.text.length <= 4 ? 4 : length);
                  i++
                )
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6.5),
                    child: AnimatedContainer(
                      key: ValueKey('profile-pin-dot-$i'),
                      duration: const Duration(milliseconds: 120),
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < value.text.length
                            ? Colors.white
                            : Colors.transparent,
                        border: Border.all(
                          color: i < value.text.length
                              ? Colors.white
                              : const Color(0xAAE4E4E7),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
          ['', '0', '⌫'],
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final key in row)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: SizedBox.square(
                      dimension: 58,
                      child: key.isEmpty
                          ? null
                          : OutlinedButton(
                              key: ValueKey('profile-pin-key-$key'),
                              style: OutlinedButton.styleFrom(
                                padding: EdgeInsets.zero,
                                shape: const CircleBorder(),
                                side: const BorderSide(
                                  color: Color(0x24FFFFFF),
                                ),
                                backgroundColor: Colors.transparent,
                                foregroundColor: const Color(0xFFF4F4F5),
                                disabledForegroundColor: const Color(
                                  0x59F4F4F5,
                                ),
                              ),
                              onPressed:
                                  enabled &&
                                      (key == '⌫'
                                          ? value.text.isNotEmpty
                                          : value.text.length < length)
                                  ? () => _press(key)
                                  : null,
                              child: key == '⌫'
                                  ? const Icon(
                                      Icons.backspace_outlined,
                                      semanticLabel: 'Backspace',
                                      size: 24,
                                    )
                                  : Text(
                                      key,
                                      style: const TextStyle(
                                        fontSize: 26,
                                        fontWeight: FontWeight.w400,
                                      ),
                                    ),
                            ),
                    ),
                  ),
              ],
            ),
          ),
      ],
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
  int? _knownLength;

  @override
  void initState() {
    super.initState();
    _loadBiometrics();
    _loadPinLength();
  }

  Future<void> _loadPinLength() async {
    try {
      final length = await widget.locks.pinLength(widget.profile.id);
      if (mounted && _pin.text.isEmpty) setState(() => _knownLength = length);
    } catch (_) {
      // Length only affects the keypad; verification can still proceed.
    }
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
    if (!ProfileLockStore.isValidNewPin(value)) {
      setState(() => _error = 'Enter a 4 or 6 digit PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    bool ok;
    try {
      ok = await widget.locks.verify(
        widget.profile.id,
        value,
        localPin: _localPin.text.trim(),
      );
    } catch (error) {
      if (!mounted) return;
      if (error is ProfileLockException && error.code == 'not_locked') {
        Navigator.of(context).pop(true);
        return;
      }
      _pin.clear();
      setState(() {
        _busy = false;
        _error = _lockErrorText(context, error);
        _needsNumericPin =
            error is ProfileLockException && error.code == 'invalid_pin';
      });
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
    if (!_needsLegacyPin) _pin.clear();
    setState(() {
      _busy = false;
      _knownLength = null;
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
      dialog: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.profile.name,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          _ProfilePinKeypad(
            controller: _pin,
            length: _knownLength ?? 6,
            unknownLength: _knownLength == null,
            enabled: !_busy,
            onComplete: _knownLength == null || _needsLegacyPin
                ? null
                : _tryUnlock,
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
              textAlign: TextAlign.center,
              style: AppText.caption.copyWith(color: AppColors.accent),
            ),
          ],
          if (_knownLength == null || _needsNumericPin)
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final changed = await manageProfilePin(
                        context,
                        profileId: widget.profile.id,
                        profileName: widget.profile.name,
                        locks: widget.locks,
                        openChange: true,
                      );
                      if (context.mounted &&
                          changed == true &&
                          widget.locks.isUnlocked(widget.profile.id)) {
                        Navigator.of(context).pop(true);
                      }
                    },
              child: Text(l10n.changeProfilePin),
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
              if (_knownLength == null || _needsLegacyPin)
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : () => _tryUnlock(),
                    child: Text(l10n.unlockProfile),
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
    required this.openChange,
  });

  final String profileId;
  final String profileName;
  final ProfileLockStore locks;
  final bool openChange;

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
  late bool _editingPin = widget.openChange;
  bool _supportsBiometrics = false;
  int? _pinLength;
  int? _currentPinLength;
  bool _confirming = false;
  bool _currentEntered = false;
  bool _legacyCurrent = false;

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
      final currentPinLength = locked
          ? await widget.locks
                .pinLength(widget.profileId)
                .catchError((Object _) => null)
          : null;
      final available = await widget.locks.canUseBiometrics;
      final enabled =
          locked && await widget.locks.biometricEnabled(widget.profileId);
      if (mounted) {
        setState(() {
          _hasLock = locked;
          _currentPinLength = currentPinLength;
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

  bool get _enteringCurrent => _hasLock == true && !_currentEntered;

  void _continueSetup() {
    if (_enteringCurrent) {
      final value = _current.text.trim();
      if (_legacyCurrent
          ? value.isEmpty
          : !ProfileLockStore.isValidNewPin(value)) {
        setState(() => _error = 'Enter your current PIN.');
        return;
      }
      setState(() {
        _currentEntered = true;
        _error = null;
      });
    } else if (_confirming) {
      _save();
    } else if (_pin.text.length == _pinLength) {
      setState(() {
        _confirming = true;
        _error = null;
      });
    } else {
      setState(() => _error = 'Enter all $_pinLength digits.');
    }
  }

  Future<void> _save() async {
    if (_busy || _hasLock == null || (_hasLock == true && !_currentEntered)) {
      return;
    }
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
    int? length;
    try {
      length = await widget.locks.pinLength(widget.profileId);
    } catch (_) {
      // Confirmation can still verify an explicitly submitted PIN.
    }
    if (!mounted) return false;
    return await _showPinDialog(
          context,
          barrierDismissible: false,
          builder: (_) => _PinConfirmationSheet(
            title: title,
            button: button,
            length: length,
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
      dialog: true,
      title: _pinLength != null
          ? _enteringCurrent
                ? 'Current PIN'
                : _confirming
                ? l10n.confirmProfilePin
                : 'Enter a new PIN'
          : _hasLock == true
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
                    textAlign: TextAlign.center,
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
                if (_pinLength == null) ...[
                  Text(
                    'Choose your PIN length',
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      for (final length in [4, 6])
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: OutlinedButton(
                              onPressed: () =>
                                  setState(() => _pinLength = length),
                              child: Text('$length digits'),
                            ),
                          ),
                        ),
                    ],
                  ),
                ] else ...[
                  if (_enteringCurrent && _legacyCurrent)
                    _pinField(
                      controller: _current,
                      hint: 'Current PIN',
                      numeric: false,
                      onSubmitted: (_) => _continueSetup(),
                    )
                  else
                    _ProfilePinKeypad(
                      controller: _enteringCurrent
                          ? _current
                          : _confirming
                          ? _confirm
                          : _pin,
                      length: _enteringCurrent
                          ? _currentPinLength ?? 6
                          : _pinLength!,
                      unknownLength:
                          _enteringCurrent && _currentPinLength == null,
                      enabled: !_busy,
                    ),
                  Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      if (_enteringCurrent && _currentPinLength == null)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _current.clear();
                                  _legacyCurrent = !_legacyCurrent;
                                }),
                          child: Text(
                            _legacyCurrent
                                ? 'Use PIN keypad'
                                : 'Use legacy PIN',
                          ),
                        )
                      else if (_hasLock == true && !_enteringCurrent)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _current.clear();
                                  _currentEntered = false;
                                  _error = null;
                                }),
                          child: const Text('Edit current PIN'),
                        ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _pin.clear();
                                _confirm.clear();
                                _pinLength = null;
                                _confirming = false;
                                _error = null;
                              }),
                        child: const Text('Change PIN length'),
                      ),
                    ],
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: AppText.caption.copyWith(color: AppColors.accent),
                  ),
                ],
                const SizedBox(height: 14),
                if (_pinLength != null)
                  FilledButton(
                    onPressed: _busy ? null : _continueSetup,
                    child: Text(
                      _busy
                          ? l10n.loading
                          : _enteringCurrent || !_confirming
                          ? 'Continue'
                          : _hasLock == true
                          ? l10n.changeProfilePin
                          : l10n.setProfilePin,
                    ),
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
    required this.length,
  });
  final String title;
  final String button;
  final int? length;
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
    final pin = _pin.text.trim();
    if (_busy || pin.isEmpty) return;
    if (!ProfileLockStore.isValidNewPin(pin)) {
      setState(() => _error = 'Enter a 4 or 6 digit PIN.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.confirm(pin);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        _pin.clear();
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
      dialog: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ProfilePinKeypad(
            controller: _pin,
            length: widget.length ?? 6,
            enabled: !_busy,
          ),
          if (_error != null)
            Text(
              _error!,
              textAlign: TextAlign.center,
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
            textAlign: TextAlign.center,
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
