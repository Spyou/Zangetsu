import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/tv/tv_text_field.dart';
import '../../core/ui/app_dialog.dart';
import '../../l10n/l10n.dart';

class StremioBackupPasswordDialog extends StatefulWidget {
  const StremioBackupPasswordDialog({super.key, required this.confirm});
  final bool confirm;
  @override
  State<StremioBackupPasswordDialog> createState() =>
      _StremioBackupPasswordDialogState();
}

class _StremioBackupPasswordDialogState
    extends State<StremioBackupPasswordDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  String? _error;

  void _submit() {
    final password = _password.text;
    final error = password.length < 8 || password.length > 1024
        ? context.l10n.passwordMustBeAtLeast8Characters
        : widget.confirm && password != _confirmation.text
        ? 'Passwords do not match.'
        : null;
    if (error != null) {
      setState(() => _error = error);
    } else {
      Navigator.of(context).pop(password);
    }
  }

  Widget _field(TextEditingController controller, String label) {
    final decoration = InputDecoration(
      labelText: label,
      errorText: controller == _password ? _error : null,
    );
    if (sl.isRegistered<AppMode>() && sl<AppMode>().isTv) {
      return TvTextField(
        controller: controller,
        decoration: decoration,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) => _submit(),
      );
    }
    return TextField(
      controller: controller,
      decoration: decoration,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      onSubmitted: (_) => _submit(),
    );
  }

  @override
  Widget build(BuildContext context) => TvAlertDialog(
    title: widget.confirm ? 'Protect addon backup' : 'Unlock addon backup',
    body: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.confirm
              ? 'Addon URLs may contain private account tokens. Keep this password to restore them on another device.'
              : 'Enter the password used when this backup was saved.',
        ),
        const SizedBox(height: 12),
        _field(_password, context.l10n.password),
        if (widget.confirm) ...[
          const SizedBox(height: 12),
          _field(_confirmation, 'Confirm password'),
        ],
      ],
    ),
    actions: [
      TvAlertAction(
        label: context.l10n.cancel,
        onTap: () => Navigator.of(context).pop(),
      ),
      TvAlertAction(
        label: 'Continue',
        primary: true,
        autofocus: true,
        onTap: _submit,
      ),
    ],
  );

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }
}
