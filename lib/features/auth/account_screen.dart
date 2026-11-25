import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/app_mode.dart';
import '../../core/cache/app_image_cache.dart';
import '../../core/di/injector.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../../l10n/l10n.dart';
import '../backup/backup_screen.dart';
import 'auth_cubit.dart';
import 'auth_screens.dart' show LoginScreen;
import 'auth_screens_tv.dart' show LoginScreenTv;
import 'pair_tv_screen.dart';
import 'reconnect.dart';

/// Sign-in, cloud backup and TV pairing for the Zangetsu account.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  static const title = 'Zangetsu account';

  static String statusLabel(BuildContext context, AuthState auth) =>
      auth.needsReconnect ? context.l10n.reconnectToSyncLibrary : 'Signed in';

  static bool get _isTv => sl.isRegistered<AppMode>() && sl<AppMode>().isTv;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(title),
      body: BlocBuilder<AuthCubit, AuthState>(
        bloc: sl<AuthCubit>(),
        builder: (context, auth) => ListView(
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 36),
          children: [
            _Header(auth: auth),
            _actions(context, signedIn: auth.isLoggedIn),
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext context, {required bool signedIn}) =>
      SettingsCard(
        radius: 26,
        children: [
          if (!signedIn)
            SettingsTile(
              icon: Icons.login_rounded,
              iconAccent: true,
              title: context.l10n.signIn,
              subtitle: context.l10n.signInSubtitle,
              autofocus: _isTv,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      _isTv ? const LoginScreenTv() : const LoginScreen(),
                ),
              ),
            ),
          if (signedIn)
            SettingsTile(
              icon: Icons.cloud_upload_outlined,
              title: context.l10n.syncLibraryToCloud,
              subtitle: context.l10n.syncLibraryToCloudSubtitle,
              subtitleMaxLines: 2,
              autofocus: _isTv,
              trailing: const SizedBox.shrink(),
              onTap: () => syncLibraryNow(context),
            ),
          SettingsTile(
            icon: Icons.cloud_sync_outlined,
            title: context.l10n.backupAndRestore,
            subtitle: context.l10n.backupAndRestoreSubtitle,
            subtitleMaxLines: 2,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const BackupScreen()),
            ),
          ),
          if (signedIn && !_isTv)
            SettingsTile(
              icon: Icons.tv_rounded,
              title: context.l10n.pairATV,
              subtitle: 'Sign a TV into this account with a code',
              onTap: () => Navigator.of(context).push(PairTvScreen.route()),
            ),
          if (signedIn)
            SettingsTile(
              icon: Icons.logout_rounded,
              title: context.l10n.logOut,
              destructive: true,
              trailing: const SizedBox.shrink(),
              onTap: () async {
                final done = await safeLogout(context);
                if (done && context.mounted) Navigator.of(context).pop();
              },
            ),
        ],
      );
}

class _Header extends StatelessWidget {
  const _Header({required this.auth});

  final AuthState auth;

  @override
  Widget build(BuildContext context) {
    final signedIn = auth.isLoggedIn;
    final email = auth.user?.email;
    final name = auth.displayName;
    final defaultViewerPhoto = sl.isRegistered<ViewerProfileStore>()
        ? sl<ViewerProfileStore>().profiles
              .where((profile) => profile.isDefault)
              .firstOrNull
              ?.photoUrl
        : null;
    final photoUrl = auth.avatarUrl?.isNotEmpty == true
        ? auth.avatarUrl
        : defaultViewerPhoto;
    final photoUri = photoUrl == null ? null : Uri.tryParse(photoUrl);
    return Card.filled(
      margin: EdgeInsets.fromLTRB(
        AccountScreen._isTv ? 28 : 16,
        0,
        AccountScreen._isTv ? 20 : 16,
        18,
      ),
      color: AppColors.surface2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: AppColors.accentSoft,
              foregroundColor: AppColors.textPrimary,
              foregroundImage:
                  signedIn &&
                      (photoUri?.scheme == 'https' ||
                          photoUri?.scheme == 'http')
                  ? AppImageCache.imageProvider(photoUrl!)
                  : null,
              child: signedIn && name.isNotEmpty
                  ? Text(
                      name.characters.first.toUpperCase(),
                      style: AppText.title,
                    )
                  : const Icon(Icons.person_outline_rounded, size: 26),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    signedIn && name.isNotEmpty
                        ? name
                        : signedIn
                        ? AccountScreen.statusLabel(context, auth)
                        : context.l10n.notSignedIn,
                    style: AppText.title,
                  ),
                  if (signedIn &&
                      email != null &&
                      email.isNotEmpty &&
                      email != name)
                    Text(
                      email,
                      style: AppText.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (signedIn && name.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(
                        AccountScreen.statusLabel(context, auth),
                        style: AppText.caption.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
