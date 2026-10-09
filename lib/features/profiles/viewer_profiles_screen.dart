import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../auth/auth_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/tv/tv_list_focusable.dart';

const Object kViewerProfileHeroTag = 'viewer-profile-selector';

class ViewerProfilesScreen extends StatefulWidget {
  const ViewerProfilesScreen({
    super.key,
    this.selectionOnly = false,
    this.onSelected,
  });

  final bool selectionOnly;
  final VoidCallback? onSelected;

  @override
  State<ViewerProfilesScreen> createState() => _ViewerProfilesScreenState();
}

class _ViewerProfilesScreenState extends State<ViewerProfilesScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pickerEntrance;
  late final Animation<double> _screenOpacity;
  late final Animation<Offset> _screenSlide;
  late final Animation<double> _titleOpacity;
  late final Animation<double> _footerOpacity;
  final _enableSelectionHero = ValueNotifier(false);
  bool _selecting = false;

  ViewerProfileStore get _profiles => sl<ViewerProfileStore>();

  /// The signed-in account's photo, for the default profile's face. Absent
  /// in widget tests and when signed out — callers fall back to icons.
  String? _accountPhoto() => sl.isRegistered<AuthCubit>()
      ? sl<AuthCubit>().state.avatarUrl
      : null;

  @override
  void initState() {
    super.initState();
    _pickerEntrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _screenOpacity = CurvedAnimation(
      parent: _pickerEntrance,
      curve: Curves.easeOutCubic,
    );
    _screenSlide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(_pickerEntrance);
    _titleOpacity = CurvedAnimation(
      parent: _pickerEntrance,
      curve: const Interval(0, 0.3, curve: Curves.easeOutCubic),
    );
    _footerOpacity = CurvedAnimation(
      parent: _pickerEntrance,
      curve: const Interval(0.7, 1, curve: Curves.easeOutCubic),
    );
    if (widget.selectionOnly) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (MediaQuery.disableAnimationsOf(context)) {
          _pickerEntrance.value = 1.0;
        } else {
          _pickerEntrance.forward();
        }
      });
    }
  }

  double _avatarStart(int i, int count, double gapScale) =>
      0.25 + (0.45 * gapScale * i / count);
  double _avatarEnd(int i, int count, double gapScale) =>
      (_avatarStart(i, count, gapScale) + 0.45 * gapScale / count + 0.15).clamp(
        0.0,
        1.0,
      );

  Animation<double> _avatarScale(int i, int count, double gapScale) =>
      Tween<double>(begin: 0.8, end: 1.0)
          .chain(CurveTween(curve: Curves.easeOutBack))
          .animate(
            CurvedAnimation(
              parent: _pickerEntrance,
              curve: Interval(
                _avatarStart(i, count, gapScale),
                _avatarEnd(i, count, gapScale),
              ),
            ),
          );

  @override
  void dispose() {
    _enableSelectionHero.dispose();
    _pickerEntrance.dispose();
    super.dispose();
  }

  Future<void> _switchTo(ViewerProfile profile) async {
    // Both the avatar and the name label land here. Sticky: every real flow
    // closes the picker after a selection, so a second tap is always a
    // double-tap, never a new choice.
    if (_selecting) return;
    _selecting = true;
    final switching = _profiles.switchTo(profile.id);
    if (!mounted) return;
    final onSelected = widget.onSelected;
    if (onSelected != null) {
      _enableSelectionHero.value = true;
      onSelected();
    }
    await switching;
    if (!mounted || onSelected != null) return;
    Navigator.of(context).pop();
  }

  Future<void> _edit([ViewerProfile? profile, int initialAvatar = 0]) async {
    final result = await showDialog<_ProfileDraft>(
      context: context,
      builder: (context) =>
          _ProfileEditor(profile: profile, initialAvatar: initialAvatar),
    );
    if (result == null) return;
    if (profile == null) {
      await _profiles.create(
        result.name,
        avatar: result.avatar,
        isKids: result.isKids,
      );
    } else {
      await _profiles.rename(profile.id, result.name);
      await _profiles.update(
        profile.id,
        avatar: result.avatar,
        isKids: result.isKids,
      );
    }
  }

  Future<void> _delete(ViewerProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete profile?'),
        content: Text(
          'Delete ${profile.name} and its saved lists and progress from this account?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _profiles.delete(profile.id);
  }

  void _openProfileManager() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ViewerProfilesScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.selectionOnly) {
      return ValueListenableBuilder<bool>(
        valueListenable: _enableSelectionHero,
        builder: (context, enabled, child) =>
            HeroMode(enabled: enabled, child: child!),
        child: FadeTransition(
          key: const ValueKey('profile-picker-entry-screen-fade'),
          opacity: _screenOpacity,
          child: SlideTransition(
            key: const ValueKey('profile-picker-entry-screen-slide'),
            position: _screenSlide,
            child: _buildProfilePicker(),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar('Profiles'),
      body: ValueListenableBuilder<int>(
        valueListenable: _profiles.revision,
        builder: (context, _, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Row(
                children: [
                  Hero(tag: kViewerProfileHeroTag, child: _profileHeaderIcon()),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Choose who is watching. Each profile keeps its own list and progress.',
                      style: AppText.caption,
                    ),
                  ),
                ],
              ),
            ),
            SettingsCard(
              children: [
                for (var i = 0; i < _profiles.profiles.length; i++) ...[
                  _profileTile(_profiles.profiles[i]),
                  if (i < _profiles.profiles.length - 1)
                    const Divider(height: 1, indent: 60),
                ],
              ],
            ),
            const SizedBox(height: 14),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.login_rounded,
                  title: 'Ask who is watching on launch',
                  subtitle: 'Choose a profile each time the app opens',
                  trailing: Switch.adaptive(
                    value: _profiles.askOnLaunch,
                    onChanged: _profiles.setAskOnLaunch,
                  ),
                  onTap: () => _profiles.setAskOnLaunch(!_profiles.askOnLaunch),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SettingsCard(
              children: [
                SettingsTile(
                  icon: Icons.person_add_alt_1_rounded,
                  title: 'Add profile',
                  subtitle:
                      _profiles.profiles.length >=
                          ViewerProfileStore.maxProfiles
                      ? 'Maximum ${ViewerProfileStore.maxProfiles} profiles reached'
                      : 'Create another profile on this account',
                  onTap:
                      _profiles.profiles.length >=
                          ViewerProfileStore.maxProfiles
                      ? null
                      : () => _edit(
                          null,
                          defaultAvatarForNewProfile(_profiles.profiles.length),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Kids profiles hide adult-rated catalogue titles. Third-party source catalogs may not have age ratings, so this is not a parental lock.',
              style: AppText.caption.copyWith(color: AppColors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfilePicker() {
    final isTv = sl.isRegistered<AppMode>() && sl<AppMode>().isTv;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: DecoratedBox(
        key: const ValueKey('profile-picker-background'),
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.7),
            radius: 1.35,
            colors: [AppColors.accent.withValues(alpha: 0.28), AppColors.bg],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final diameter = constraints.maxWidth >= 900
                  ? 124.0
                  : constraints.maxWidth >= 600
                  ? 112.0
                  : 104.0;
              final wide = constraints.maxWidth >= 900;
              final availableGridWidth = math.max(
                0.0,
                constraints.maxWidth - (wide ? 96 : 32),
              );
              final gridWidth = math.min(
                (diameter + 28) * 2 + 64,
                availableGridWidth,
              );
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Align(
                    alignment: Alignment.center,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: wide ? 48 : 16,
                        vertical: wide ? 24 : 12,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: isTv ? 1400 : 820,
                        ),
                        child: ValueListenableBuilder<int>(
                          valueListenable: _profiles.revision,
                          builder: (context, _, _) {
                            final lastName = _profiles.active.value?.name;
                            return Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              FadeTransition(
                                key: const ValueKey(
                                  'profile-picker-title-fade',
                                ),
                                opacity: _titleOpacity,
                                child: Column(
                                  children: [
                                    Text(
                                      "Who's watching?",
                                      textAlign: TextAlign.center,
                                      style: AppText.title.copyWith(
                                        fontSize: wide ? 36 : 30,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      lastName == null
                                          ? 'Select a profile to continue'
                                          : 'Ready for the next watch, $lastName?',
                                      textAlign: TextAlign.center,
                                      style: AppText.caption.copyWith(
                                        color: AppColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(height: wide ? 36 : 32),
                              _pickerGrid(
                                diameter: diameter,
                                gridWidth: gridWidth,
                                isTv: isTv,
                                gapScale: isTv ? 0.5 : 1.0,
                              ),
                              const SizedBox(height: 8),
                              FadeTransition(
                                key: const ValueKey(
                                  'profile-picker-footer-fade',
                                ),
                                opacity: _footerOpacity,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _manageProfilesButton(isTv),
                                    SizedBox(height: wide ? 20 : 14),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 620,
                                      ),
                                      child: Text(
                                        'Kids profiles hide adult-rated titles only when catalogue ratings are available. They are not a parental lock.',
                                        textAlign: TextAlign.center,
                                        style: AppText.caption.copyWith(
                                          color: AppColors.textTertiary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _manageProfilesButton(bool isTv) {
    if (isTv) {
      return TvListFocusable(
        waitForKeyUp: true,
        semanticLabel: 'Manage profiles',
        onTap: _openProfileManager,
        builder: (focused) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: focused ? AppColors.accent : AppColors.hairline,
            ),
            color: focused
                ? AppColors.accent.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.manage_accounts_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Text('Manage profiles', style: AppText.button),
            ],
          ),
        ),
      );
    }

    return TextButton.icon(
      onPressed: _openProfileManager,
      icon: const Icon(Icons.manage_accounts_rounded, size: 18),
      label: const Text('Manage profiles'),
    );
  }

  Widget _pickerGrid({
    required double diameter,
    required double gridWidth,
    required bool isTv,
    required double gapScale,
  }) {
    final profiles = _profiles.profiles;
    final hasAddTile = profiles.length < ViewerProfileStore.maxProfiles;
    final count = profiles.length + (hasAddTile ? 1 : 0);
    return SizedBox(
      width: gridWidth.toDouble(),
      child: GridView.count(
        key: const ValueKey('profile-picker-grid'),
        crossAxisCount: 2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 12,
        mainAxisExtent: diameter + 56,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (var i = 0; i < profiles.length; i++)
            ScaleTransition(
              key: ValueKey('profile-entrance-${profiles[i].id}'),
              scale: _avatarScale(i, count, gapScale),
              child: _profilePickerChoice(
                profile: profiles[i],
                diameter: diameter,
                isTv: isTv,
                autofocus: i == 0,
              ),
            ),
          if (hasAddTile)
            ScaleTransition(
              key: const ValueKey('profile-entrance-add'),
              scale: _avatarScale(profiles.length, count, gapScale),
              child: _addProfilePickerChoice(
                diameter: diameter,
                isTv: isTv,
                autofocus: profiles.isEmpty,
              ),
            ),
        ],
      ),
    );
  }

  Widget _profilePickerChoice({
    required ViewerProfile profile,
    required double diameter,
    required bool isTv,
    required bool autofocus,
  }) {
    final selected = _profiles.activeId == profile.id;
    final fill = viewerProfileAvatarColor(profile.avatar);
    final avatarKey = GlobalKey<_ProfileAvatarTapTargetState>();
    final photo = accountPhotoForProfile(
      isDefault: profile.isDefault,
      accountPhotoUrl: _accountPhoto(),
    );

    Widget content(bool focused) => SizedBox(
      width: diameter + 28,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ProfileAvatarTapTarget(
            key: avatarKey,
            profileId: profile.id,
            diameter: diameter,
            fill: fill,
            focused: focused,
            selected: selected,
            onTap: () => _switchTo(profile),
            child: ProfileAvatarFace(
              profile: profile,
              photoUrl: photo,
              iconSize: diameter * 0.42,
              photoDiameter: diameter,
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _switchTo(profile),
            child: Column(
              children: [
                const SizedBox(height: 6),
                Text(
                  profile.name,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.headline.copyWith(
                    color: focused || selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    fontSize: isTv ? 18 : 15,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
                if (profile.isKids) ...[
                  const SizedBox(height: 3),
                  Text(
                    'KIDS',
                    style: AppText.overline.copyWith(
                      color: AppColors.accent,
                      fontSize: 10,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    if (isTv) {
      return TvListFocusable(
        autofocus: autofocus,
        semanticLabel: 'Select profile ${profile.name}',
        onTap: () {
          final avatar = avatarKey.currentState;
          if (avatar == null) {
            _switchTo(profile);
          } else {
            avatar.runSelection();
          }
        },
        builder: content,
      );
    }
    return content(false);
  }

  Widget _addProfilePickerChoice({
    required double diameter,
    required bool isTv,
    required bool autofocus,
  }) {
    Widget content(bool focused) => SizedBox(
      width: diameter + 28,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: focused ? AppColors.textPrimary : AppColors.hairline,
                width: 2.5,
              ),
              boxShadow: focused
                  ? [
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.3),
                        blurRadius: 24,
                      ),
                    ]
                  : const [],
            ),
            child: CircleAvatar(
              radius: diameter / 2,
              backgroundColor: AppColors.surface2,
              child: Icon(
                Icons.add_rounded,
                size: diameter * 0.42,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Add profile',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.headline.copyWith(
              color: AppColors.textSecondary,
              fontSize: isTv ? 18 : 15,
            ),
          ),
        ],
      ),
    );

    if (isTv) {
      return TvListFocusable(
        autofocus: autofocus,
        semanticLabel: 'Add profile',
        onTap: () =>
            _edit(null, defaultAvatarForNewProfile(_profiles.profiles.length)),
        builder: content,
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(diameter),
      onTap: () =>
          _edit(null, defaultAvatarForNewProfile(_profiles.profiles.length)),
      child: content(false),
    );
  }

  Widget _profileHeaderIcon() => Container(
    width: 34,
    height: 34,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: AppColors.accent.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(
      Icons.switch_account_rounded,
      color: AppColors.accent,
      size: 19,
    ),
  );

  Widget _profileTile(ViewerProfile profile) {
    final selected = _profiles.activeId == profile.id;
    return SettingsTile(
      icon: viewerProfileAvatarIcon(profile.avatar),
      leading: Container(
        key: ValueKey('profile-tile-avatar-${profile.id}'),
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: viewerProfileAvatarColor(profile.avatar),
        ),
        child: ProfileAvatarFace(
          profile: profile,
          photoUrl: accountPhotoForProfile(
            isDefault: profile.isDefault,
            accountPhotoUrl: _accountPhoto(),
          ),
          iconSize: 19,
          photoDiameter: 34,
        ),
      ),
      title: profile.name,
      subtitle: profile.isKids
          ? 'Kids profile'
          : (profile.isDefault ? 'Default profile' : 'Profile'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected)
            Icon(Icons.check_circle_rounded, color: AppColors.accent),
          IconButton(
            tooltip: 'Edit ${profile.name}',
            onPressed: () => _edit(profile),
            icon: const Icon(Icons.edit_outlined, size: 19),
          ),
          if (!profile.isDefault)
            IconButton(
              tooltip: 'Delete ${profile.name}',
              onPressed: () => _delete(profile),
              icon: const Icon(Icons.delete_outline_rounded, size: 19),
            ),
        ],
      ),
      onTap: () => _switchTo(profile),
    );
  }
}

class _ProfileAvatarTapTarget extends StatefulWidget {
  const _ProfileAvatarTapTarget({
    super.key,
    required this.profileId,
    required this.diameter,
    required this.fill,
    required this.focused,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String profileId;
  final double diameter;
  final Color fill;
  final bool focused;
  final bool selected;
  final Future<void> Function() onTap;
  final Widget child;

  @override
  State<_ProfileAvatarTapTarget> createState() =>
      _ProfileAvatarTapTargetState();
}

class _ProfileAvatarTapTargetState extends State<_ProfileAvatarTapTarget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  TickerFuture? _releaseAnimation;
  bool _activating = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1,
          end: 0.94,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 25,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 0.94,
          end: 1.05,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 35,
      ),
      TweenSequenceItem(
        tween: Tween<double>(
          begin: 1.05,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 40,
      ),
    ]).animate(_controller);
  }

  Future<void> runSelection() async {
    if (_activating) return;
    _activating = true;
    _releaseAnimation ??= _controller.forward();
    try {
      await widget.onTap();
    } finally {
      _releaseAnimation = null;
      _activating = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.diameter + 8,
    child: Listener(
      onPointerDown: (_) {
        if (!_activating) {
          _releaseAnimation = null;
          _controller.animateTo(
            0.25,
            duration: const Duration(milliseconds: 65),
            curve: Curves.easeOutCubic,
          );
        }
      },
      onPointerUp: (_) {
        if (!_activating) _releaseAnimation ??= _controller.forward();
      },
      onPointerCancel: (_) {
        _releaseAnimation = null;
        if (!_activating) {
          _controller.animateBack(
            0,
            duration: const Duration(milliseconds: 100),
            curve: Curves.easeOutCubic,
          );
        }
      },
      child: ScaleTransition(
        key: ValueKey('profile-avatar-${widget.profileId}'),
        scale: _scale,
        child: Hero(
          tag: viewerProfileHeroTag(widget.profileId),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.focused
                    ? AppColors.textPrimary
                    : widget.selected
                    ? AppColors.accent
                    : Colors.transparent,
                width: 2.5,
              ),
              boxShadow: widget.selected || widget.focused
                  ? [
                      BoxShadow(
                        color: AppColors.accent.withValues(
                          alpha: widget.focused ? 0.30 : 0.18,
                        ),
                        blurRadius: widget.focused ? 24 : 18,
                      ),
                    ]
                  : const [],
            ),
            child: Material(
              key: ValueKey('profile-avatar-fill-${widget.profileId}'),
              color: widget.fill,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkResponse(
                key: ValueKey('profile-avatar-ink-${widget.profileId}'),
                containedInkWell: true,
                highlightShape: BoxShape.circle,
                customBorder: const CircleBorder(),
                radius: widget.diameter / 2,
                splashColor: AppColors.textPrimary.withValues(alpha: 0.28),
                highlightColor: AppColors.textPrimary.withValues(alpha: 0.10),
                onTap: runSelection,
                child: SizedBox.square(
                  dimension: widget.diameter,
                  child: Center(child: widget.child),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ProfileDraft {
  const _ProfileDraft(this.name, this.avatar, this.isKids);
  final String name;
  final int avatar;
  final bool isKids;
}

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({this.profile, this.initialAvatar = 0});
  final ViewerProfile? profile;
  final int initialAvatar;

  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.profile?.name ?? '',
  );
  late int _avatar = widget.profile?.avatar ?? widget.initialAvatar;
  late bool _isKids = widget.profile?.isKids ?? false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.profile == null ? 'Add profile' : 'Edit profile'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: ViewerProfileStore.maxNameLength,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < viewerProfileAvatarIcons.length; i++)
                  IconButton.filledTonal(
                    tooltip: 'Avatar ${i + 1}',
                    onPressed: () => setState(() => _avatar = i),
                    style: IconButton.styleFrom(
                      backgroundColor: _avatar == i
                          ? AppColors.accentSoft
                          : AppColors.surface2,
                    ),
                    icon: Icon(
                      viewerProfileAvatarIcons[i],
                      color: _avatar == i
                          ? AppColors.accent
                          : AppColors.textSecondary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Kids profile'),
              subtitle: const Text('Hide adult catalogue titles'),
              value: _isKids,
              onChanged: (value) => setState(() => _isKids = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, _ProfileDraft(name, _avatar, _isKids));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
