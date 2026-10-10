import 'package:flutter/material.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../auth/auth_cubit.dart';
import '../settings/settings_screen.dart';
import '../../l10n/l10n.dart';
import 'viewer_profile_editor_screen.dart';
import 'viewer_profiles_screen.dart';

class ViewerProfileHomeScreen extends StatelessWidget {
  const ViewerProfileHomeScreen({super.key});

  ViewerProfileStore get _profiles => sl<ViewerProfileStore>();

  String? _accountPhoto() =>
      sl.isRegistered<AuthCubit>() ? sl<AuthCubit>().state.avatarUrl : null;

  void _openSettings(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const SettingsScreen(showBackButton: true),
      ),
    );
  }

  void _openManager(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ViewerProfilesScreen()),
    );
  }

  Future<void> _editActive(BuildContext context) => openViewerProfileEditor(
    context,
    _profiles,
    profile: _profiles.activeProfile,
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.bg,
    appBar: settingsAppBar(
      context.l10n.profile,
      showBack: false,
      actions: [
        IconButton(
          tooltip: 'App settings',
          onPressed: () => _openSettings(context),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    body: ValueListenableBuilder<int>(
      valueListenable: _profiles.revision,
      builder: (context, _, _) => LayoutBuilder(
        builder: (context, constraints) {
          final avatarSize = constraints.maxWidth >= 640 ? 96.0 : 82.0;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 124),
                children: [
                  _activeProfileCard(
                    context,
                    _profiles.activeProfile,
                    avatarSize,
                  ),
                  const SizedBox(height: 26),
                  Text('Switch profile', style: AppText.headline),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 20,
                    runSpacing: 18,
                    children: [
                      for (final profile in _profiles.profiles)
                        _profileChoice(profile, avatarSize - 18),
                    ],
                  ),
                  const SizedBox(height: 28),
                  SettingsCard(
                    children: [
                      SettingsTile(
                        icon: Icons.manage_accounts_rounded,
                        title: 'Manage profiles',
                        subtitle: 'Add, edit, or remove profiles',
                        onTap: () => _openManager(context),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _activeProfileCard(
    BuildContext context,
    ViewerProfile profile,
    double avatarSize,
  ) {
    final photo = profilePhotoForFace(
      profile: profile,
      accountPhotoUrl: _accountPhoto(),
    );
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.settingsCard,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Container(
            width: avatarSize,
            height: avatarSize,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.accent.withValues(alpha: 0.7),
                width: 2,
              ),
            ),
            child: CircleAvatar(
              radius: (avatarSize - 8) / 2,
              backgroundColor: viewerProfileAvatarColor(profile.avatar),
              child: ProfileAvatarFace(
                profile: profile,
                photoUrl: photo,
                iconSize: avatarSize * 0.4,
                photoDiameter: avatarSize - 8,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Active profile',
                  style: AppText.overline.copyWith(color: AppColors.accent),
                ),
                const SizedBox(height: 3),
                Text(
                  profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.title.copyWith(fontSize: 24),
                ),
                if (profile.isKids) ...[
                  const SizedBox(height: 3),
                  Text('Kids profile', style: AppText.caption),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Edit profile',
            onPressed: () => _editActive(context),
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
    );
  }

  Widget _profileChoice(ViewerProfile profile, double diameter) {
    final selected = _profiles.activeId == profile.id;
    final photo = profilePhotoForFace(
      profile: profile,
      accountPhotoUrl: _accountPhoto(),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '${profile.name}${selected ? ', active profile' : ''}',
      child: InkWell(
        key: ValueKey('profile-home-choice-${profile.id}'),
        borderRadius: BorderRadius.circular(18),
        onTap: () => _profiles.switchTo(profile.id),
        child: SizedBox(
          width: diameter + 28,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: diameter + 8,
                height: diameter + 8,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? AppColors.accent : Colors.transparent,
                    width: 2.5,
                  ),
                ),
                child: CircleAvatar(
                  radius: diameter / 2,
                  backgroundColor: viewerProfileAvatarColor(profile.avatar),
                  child: ProfileAvatarFace(
                    profile: profile,
                    photoUrl: photo,
                    iconSize: diameter * 0.42,
                    photoDiameter: diameter,
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                profile.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(
                  color: selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
