import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../core/cache/app_image_cache.dart';
import '../../core/di/injector.dart';
import '../../core/models/watch_status.dart';
import '../../core/playback/list_status_store.dart';
import '../../core/playback/my_list.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart' show ProfileAccountSection;
import '../companion/companion_settings_screen.dart';
import '../settings/settings_screen.dart';
import 'viewer_profile_editor_screen.dart';
import 'viewer_profiles_screen.dart';

class ViewerProfileHomeScreen extends StatelessWidget {
  const ViewerProfileHomeScreen({
    super.key,
    this.onProfileSelected,
    this.onPickerClosed,
  });

  final VoidCallback? onProfileSelected;
  final VoidCallback? onPickerClosed;

  ViewerProfileStore get _profiles => sl<ViewerProfileStore>();

  String? _accountPhoto() =>
      sl.isRegistered<AuthCubit>() ? sl<AuthCubit>().state.avatarUrl : null;

  void _openSettings(BuildContext context) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => const SettingsScreen(showBackButton: true),
    ),
  );

  Future<void> _openChooser(BuildContext context) async {
    final route = ProfilePickerRoute(
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      builder: (pickerContext) => ViewerProfilesScreen(
        selectionOnly: true,
        onProfilePrepared: onProfileSelected,
        onSelected: onProfileSelected == null
            ? null
            : () async {
                await WidgetsBinding.instance.endOfFrame;
                if (pickerContext.mounted) Navigator.of(pickerContext).pop();
              },
      ),
    );
    await Navigator.of(context).push<void>(route);
    await route.completed;
    onPickerClosed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.select<AuthCubit, AuthState>((cubit) => cubit.state);
    if (auth.status == AuthStatus.unknown) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(child: CircularProgressIndicator(color: AppColors.accent)),
      );
    }
    if (!auth.isLoggedIn) {
      return Scaffold(backgroundColor: AppColors.bg, body: _signedOut(context));
    }

    final myList = sl.isRegistered<MyListStore>() ? sl<MyListStore>() : null;
    final statuses = sl.isRegistered<ListStatusStore>()
        ? sl<ListStatusStore>()
        : null;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: AnimatedBuilder(
        animation: Listenable.merge([
          _profiles.revision,
          if (myList != null) myList.revision,
          if (statuses != null) statuses.revision,
        ]),
        builder: (context, _) {
          final profile = _profiles.activeProfile;
          final saved = myList?.all() ?? [];
          final inProgress = statuses == null
              ? 0
              : saved
                    .where(
                      (item) => statuses.statusOf(item) == WatchStatus.watching,
                    )
                    .length;
          final completed = statuses == null
              ? 0
              : saved
                    .where(
                      (item) =>
                          statuses.statusOf(item) == WatchStatus.completed,
                    )
                    .length;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _cover(context, profile),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 124),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          switchInCurve: Curves.easeOutCubic,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, 0.08),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: Column(
                            key: ValueKey(profile.id),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      profile.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.title,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Edit profile',
                                    onPressed: () => openViewerProfileEditor(
                                      context,
                                      _profiles,
                                      profile: profile,
                                    ),
                                    icon: const Icon(
                                      Icons.edit_outlined,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                              if (profile.isKids)
                                Text('Kids profile', style: AppText.caption),
                              GestureDetector(
                                onTap: () => openViewerProfileEditor(
                                  context,
                                  _profiles,
                                  profile: profile,
                                ),
                                child: Text(
                                  profile.bio.isEmpty
                                      ? 'Add a bio'
                                      : profile.bio,
                                  style: AppText.body.copyWith(
                                    fontSize: 14,
                                    color: profile.bio.isEmpty
                                        ? AppColors.textTertiary
                                        : AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 26),
                        _stats(saved.length, inProgress, completed),
                        const SizedBox(height: 30),
                        Divider(height: 1, color: AppColors.hairline),
                        const SizedBox(height: 22),
                        _featureGrid(context),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _signedOut(BuildContext context) => SafeArea(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
          child: Row(
            children: [
              Text('Profile', style: AppText.title),
              const Spacer(),
              IconButton(
                tooltip: 'Settings',
                onPressed: () => _openSettings(context),
                style: IconButton.styleFrom(
                  foregroundColor: AppColors.textPrimary,
                  backgroundColor: AppColors.surface,
                  shape: const CircleBorder(),
                ),
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: const ProfileAccountSection(),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _cover(BuildContext context, ViewerProfile profile) {
    final photo = profilePhotoForFace(
      profile: profile,
      accountPhotoUrl: _accountPhoto(),
    );
    final topInset = MediaQuery.paddingOf(context).top;
    final imageWidth =
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round()
            .clamp(1, 1600);
    return SizedBox(
      height: topInset + 190,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: Stack(
              fit: StackFit.expand,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [AppColors.surface, AppColors.bg],
                    ),
                  ),
                ),
                if (profile.coverUrl != null)
                  CachedNetworkImage(
                    imageUrl: profile.coverUrl!,
                    cacheManager: AppImageCache.cacheManagerOrDefault,
                    fit: BoxFit.cover,
                    memCacheWidth: imageWidth,
                    fadeInDuration: const Duration(milliseconds: 240),
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  ),
                if (profile.coverUrl != null)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          AppColors.bg.withValues(alpha: 0.04),
                          AppColors.bg.withValues(alpha: 0.22),
                          AppColors.bg,
                        ],
                        stops: const [0, 0.52, 0.82, 1],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            top: topInset + 10,
            left: 20,
            right: 20,
            child: Row(
              children: [
                Material(
                  color: AppColors.bg.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(24),
                  child: InkWell(
                    key: const ValueKey('profile-home-switch'),
                    borderRadius: BorderRadius.circular(24),
                    onTap: () => _openChooser(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 180),
                            child: Text(
                              profile.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.button,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Settings',
                  onPressed: () => _openSettings(context),
                  style: IconButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    backgroundColor: Colors.black.withValues(alpha: 0.5),
                    shape: const CircleBorder(),
                  ),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: -18,
            left: 20,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutCubic,
              child: Semantics(
                key: ValueKey(profile.id),
                label: '${profile.name} avatar',
                child: Container(
                  width: 90,
                  height: 90,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.bg,
                  ),
                  child: CircleAvatar(
                    backgroundColor: viewerProfileAvatarColor(profile.avatar),
                    child: ProfileAvatarFace(
                      profile: profile,
                      photoUrl: photo,
                      iconSize: 38,
                      photoDiameter: 84,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stats(int saved, int inProgress, int completed) => Row(
    children: [
      _stat('$saved', 'My List'),
      _stat('$inProgress', 'In progress'),
      _stat('$completed', 'Completed'),
    ],
  );

  /// Opens the phone remote (moved here from the dock) as a pushed page with
  /// a back button, so it polls the TV only while it is on screen.
  void _openRemote(BuildContext context) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => const CompanionSettingsScreen(showBack: true),
    ),
  );

  /// The profile's feature tiles, in grid order. Add a feature by adding an
  /// entry here; the grid lays it out.
  List<_ProfileFeature> _features(BuildContext context) => [
    _ProfileFeature(
      key: const ValueKey('profile-remote-entry'),
      icon: Icons.settings_remote_rounded,
      label: 'Remote',
      hint: 'Control your TV with this phone',
      onTap: () => _openRemote(context),
    ),
  ];

  /// Spacing between feature tiles, both across and between rows.
  static const double _featureGap = 12;

  /// Narrowest a tile may get before the grid drops a column.
  static const double _featureMinTile = 84;

  /// 3 columns on phones, 4 on tablets, 5 on wide layouts, 6 on very wide.
  static int _featureColumns(double width) {
    if (width < 600) return 3;
    if (width < 900) return 4;
    return width < 1280 ? 5 : 6;
  }

  /// A non-scrolling grid inside the page's ListView. Tiles are equal width
  /// and at least square; they grow taller (never overflow) at large text.
  Widget _featureGrid(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final features = _features(context);
      // Never squeeze tiles below _featureMinTile (split screen, or a
      // window narrower than the screen).
      final fit =
          ((constraints.maxWidth + _featureGap) /
                  (_featureMinTile + _featureGap))
              .floor()
              .clamp(1, 99);
      final byScreen = _featureColumns(MediaQuery.sizeOf(context).width);
      final columns = byScreen < fit ? byScreen : fit;
      final tileWidth =
          ((constraints.maxWidth - _featureGap * (columns - 1)) / columns)
              .floorToDouble();
      return Wrap(
        spacing: _featureGap,
        runSpacing: _featureGap,
        children: [
          for (final feature in features)
            SizedBox(width: tileWidth, child: _featureTile(feature, tileWidth)),
        ],
      );
    },
  );

  /// One rounded tile: icon badge over a one-line label, read by screen
  /// readers as a single button. [size] is the tile width and minimum height.
  Widget _featureTile(_ProfileFeature feature, double size) => Semantics(
    container: true,
    button: true,
    label: feature.label,
    hint: feature.hint,
    child: Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: AppColors.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: feature.key,
        onTap: feature.onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: size),
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: AppColors.accentSoft,
                    ),
                    child: Icon(
                      feature.icon,
                      size: 26,
                      color: AppColors.accent,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Large text shrinks to fit the tile instead of clipping
                  // the word.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      feature.label,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: AppText.button.copyWith(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _stat(String value, String label) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppText.title),
        const SizedBox(height: 3),
        Text(label, style: AppText.caption),
      ],
    ),
  );
}

/// One tile in the profile feature grid: what it shows and what tapping does.
class _ProfileFeature {
  const _ProfileFeature({
    required this.key,
    required this.icon,
    required this.label,
    required this.hint,
    required this.onTap,
  });

  /// Key on the tile's InkWell, used by widget tests to find and tap it.
  final Key key;
  final IconData icon;

  /// Short title under the icon, also the semantics label.
  final String label;

  /// Screen-reader hint describing what the feature does.
  final String hint;
  final VoidCallback onTap;
}
