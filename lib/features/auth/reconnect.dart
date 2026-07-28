import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/playback/my_list.dart';
import '../../core/playback/watch_history.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/buttons.dart';
import 'auth_cubit.dart';

/// Make sure the app has a LIVE Supabase session before a cloud write. When the
/// session has lapsed (the user is logged-in from cache only) this prompts for
/// the password and re-authenticates IN PLACE — no logout, so the local library
/// is never wiped. Returns true if we ended up with a live session.
Future<bool> ensureLiveSession(BuildContext context) async {
  final cubit = sl<AuthCubit>();
  if (cubit.state.user == null) return false; // genuinely signed out
  // Verify by actually refreshing the token — the only reliable check. A stored
  // session can look valid yet 401 every write; refreshSession() proves it and
  // revives it silently when the refresh token is alive (no password needed).
  if (await cubit.ensureFreshSession()) return true;
  if (!context.mounted) return false;
  final ok = await showReconnectDialog(context);
  return ok ?? false;
}

/// Password re-entry dialog that revives the session for the current account.
/// Returns true on success, null/false if dismissed or wrong password.
Future<bool?> showReconnectDialog(BuildContext context) => showDialog<bool>(
      context: context,
      builder: (_) => const _ReconnectDialog(),
    );

/// Best-effort push of the local library to the cloud when a live session
/// exists — so a following logout/clearLocal can't lose it. No-op otherwise.
Future<void> backupLibraryIfPossible() async {
  if (!sl<AuthCubit>().hasLiveSession) return;
  await sl<WatchHistory>().pushAllLocalToCloud();
  await sl<MyListStore>().pushAllLocalToCloud();
}

/// Log out WITHOUT losing an un-backed-up library. If there's local data and a
/// live session, push it to the cloud first; if there's local data and no live
/// session, warn (the logout-time [MyListStore.clearLocal] wipes local, and an
/// empty cloud means it can't be restored). Returns true if logout happened.
Future<bool> safeLogout(BuildContext context) async {
  final cubit = sl<AuthCubit>();
  final hasLocal =
      sl<WatchHistory>().all().isNotEmpty || sl<MyListStore>().all().isNotEmpty;
  if (hasLocal) {
    if (cubit.hasLiveSession) {
      // Back the library up before the logout wipes the local cache.
      await backupLibraryIfPossible();
    } else {
      final choice = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Back up before logging out?', style: AppText.title),
          content: Text(
            "Your library isn't saved to the cloud yet, so logging out will "
            'remove it from this device. Reconnect to back it up first?',
            style: AppText.caption,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: Text('Cancel', style: AppText.button),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'anyway'),
              child: Text('Log out anyway',
                  style: AppText.button.copyWith(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'reconnect'),
              child: Text('Reconnect', style: AppText.button.copyWith(color: AppColors.accent)),
            ),
          ],
        ),
      );
      if (choice == null || choice == 'cancel') return false;
      if (choice == 'reconnect') {
        if (!context.mounted) return false;
        final ok = await ensureLiveSession(context);
        if (!ok) return false; // couldn't reconnect → don't risk the wipe
        await backupLibraryIfPossible();
      }
      // 'anyway' → fall through: the user accepted losing the local copy.
    }
  }
  await cubit.logout();
  return true;
}

class _ReconnectDialog extends StatefulWidget {
  const _ReconnectDialog();
  @override
  State<_ReconnectDialog> createState() => _ReconnectDialogState();
}

class _ReconnectDialogState extends State<_ReconnectDialog> {
  final _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _pw.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await sl<AuthCubit>().reconnect(_pw.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = sl<AuthCubit>().state.error ?? 'Wrong password';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = sl<AuthCubit>().state.user?.email ?? '';
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reconnect to sync', style: AppText.title),
            const SizedBox(height: 6),
            Text(
              'Your session expired. Enter your password to reconnect '
              '${email.isEmpty ? "your account" : email} and sync your library.',
              style: AppText.caption,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pw,
              obscureText: true,
              autofocus: true,
              enabled: !_busy,
              onSubmitted: (_) => _submit(),
              style: AppText.body,
              decoration: InputDecoration(
                hintText: 'Password',
                hintStyle: AppText.body.copyWith(color: AppColors.textTertiary),
                filled: true,
                fillColor: AppColors.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: AppText.caption.copyWith(color: AppColors.accent)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: _busy ? 'Reconnecting…' : 'Reconnect',
                onPressed: _busy ? null : _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
