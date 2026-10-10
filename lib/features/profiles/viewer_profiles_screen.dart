import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';

import '../../core/app_mode.dart';
import '../../core/di/injector.dart';
import '../../core/models/media_item.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/profiles/profile_picker_artwork.dart';
import '../../core/app_config.dart';
import '../auth/auth_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/image_fade.dart';
import '../../core/ui/native_cover_provider.dart';
import '../../core/ui/settings_widgets.dart';
import '../../core/tv/tv_list_focusable.dart';
import '../../l10n/l10n.dart';
import '../home/cubit/home_cubit.dart';
import '../auth/auth_screens.dart' show ProfileAccountSection;
import 'viewer_profile_editor_screen.dart';

const Object kViewerProfileHeroTag = 'viewer-profile-selector';

String _pickerBackdropUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host != 'image.tmdb.org') return url;
  final segments = uri.pathSegments;
  if (segments.length < 4 ||
      segments[0] != 't' ||
      segments[1] != 'p' ||
      !const {'w500', 'w780'}.contains(segments[2])) {
    return url;
  }
  return uri
      .replace(
        pathSegments: [...segments.take(2), 'w1280', ...segments.skip(3)],
      )
      .toString();
}

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
  bool _managingProfiles = false;
  String? _pickerArtworkUrl;
  ProfilePickerArtwork? _pickerArtwork;
  Timer? _artworkRotation;

  ViewerProfileStore get _profiles => sl<ViewerProfileStore>();

  /// The signed-in account's photo, for the default profile's face. Absent
  /// in widget tests and when signed out — callers fall back to icons.
  String? _accountPhoto() =>
      sl.isRegistered<AuthCubit>() ? sl<AuthCubit>().state.avatarUrl : null;

  MediaItem? _pickerBackdropItem() {
    if (!sl.isRegistered<HomeCubit>()) return null;
    for (final item in sl<HomeCubit>().state.heroItems) {
      if (item.isAdult) continue;
      final art = item.banner ?? item.cover;
      if (art != null && art.isNotEmpty) return item;
    }
    return null;
  }

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
      if (Hive.isBoxOpen(ViewerProfileStore.boxName)) {
        final artwork = _pickerArtwork = ProfilePickerArtwork(
          box: Hive.box(ViewerProfileStore.boxName),
          fetchManifest: () async => (await sl<Dio>().get<Object>(
            kProfilePickerArtworkManifestUrl,
            options: Options(receiveTimeout: const Duration(seconds: 4)),
          )).data,
        );
        _pickerArtworkUrl = artwork.cachedUrl;
        if (sl.isRegistered<Dio>()) unawaited(_loadNextArtwork());
      }
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

  Future<void> _loadNextArtwork() async {
    final artwork = _pickerArtwork;
    if (artwork == null) return;
    final url = await artwork.next();
    if (!mounted || url == null) return;
    if (url != _pickerArtworkUrl) setState(() => _pickerArtworkUrl = url);
    if (artwork.canRotate) {
      _artworkRotation ??= Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_loadNextArtwork());
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
    _artworkRotation?.cancel();
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
    await openViewerProfileEditor(
      context,
      _profiles,
      profile: profile,
      initialAvatar: initialAvatar,
    );
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
    if (confirmed != true) return;
    final deleted = await _profiles.delete(profile.id);
    if (!deleted && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.offlineBody)));
    }
  }

  void _openProfileManager() {
    setState(() => _managingProfiles = true);
  }

  void _closeProfileManager() {
    setState(() => _managingProfiles = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.selectionOnly && !_managingProfiles) {
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
      appBar: settingsAppBar(
        'Profiles',
        onBack: widget.selectionOnly ? _closeProfileManager : null,
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _profiles.revision,
        builder: (context, _, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 36),
          children: [
            if (sl.isRegistered<AuthCubit>()) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Text('Account', style: AppText.headline),
              ),
              BlocProvider.value(
                value: sl<AuthCubit>(),
                child: const ProfileAccountSection(),
              ),
              const Divider(height: 1),
            ],
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
    final backdrop = _pickerBackdropItem();
    final screenSize = MediaQuery.sizeOf(context);
    final useWideArt = isTv || screenSize.width >= screenSize.height;
    final sourceBackdropUrl = useWideArt
        ? backdrop?.banner ?? backdrop?.cover
        : backdrop?.cover ?? backdrop?.banner;
    final backdropUrl =
        _pickerArtworkUrl ??
        (sourceBackdropUrl == null
            ? null
            : _pickerBackdropUrl(sourceBackdropUrl));
    final backdropProvider = backdropUrl == null || backdropUrl.isEmpty
        ? null
        : nativeCoverProvider(
            backdropUrl,
            _pickerArtworkUrl == null ? backdrop?.coverHeaders : null,
          );
    final backdropWidth = math
        .min(
          (MediaQuery.sizeOf(context).width *
                  MediaQuery.devicePixelRatioOf(context))
              .round(),
          2560,
        )
        .toInt();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            key: const ValueKey('profile-picker-background'),
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.7),
                radius: 1.35,
                colors: [
                  AppColors.accent.withValues(alpha: 0.28),
                  AppColors.bg,
                ],
              ),
            ),
          ),
          if (backdropProvider != null)
            Positioned.fill(
              bottom: useWideArt ? 0 : screenSize.height * 0.4,
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: AnimatedSwitcher(
                    key: const ValueKey('profile-picker-backdrop-switcher'),
                    duration: const Duration(milliseconds: 900),
                    reverseDuration: const Duration(milliseconds: 700),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      final curved = CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                        reverseCurve: Curves.easeInCubic,
                      );
                      return FadeTransition(
                        opacity: curved,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0.025, 0),
                            end: Offset.zero,
                          ).animate(curved),
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: 1.04,
                              end: 1,
                            ).animate(curved),
                            child: child,
                          ),
                        ),
                      );
                    },
                    child: SizedBox.expand(
                      key: ValueKey(backdropUrl),
                      child: Image(
                        key: const ValueKey('profile-picker-backdrop-image'),
                        image: ResizeImage(
                          backdropProvider,
                          width: backdropWidth,
                        ),
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        frameBuilder: imageFadeIn,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: isTv
                        ? const [0, 0.18, 0.42, 0.72, 1]
                        : const [0, 0.2, 0.36, 0.56, 1],
                    colors: isTv
                        ? [
                            AppColors.bg.withValues(alpha: 0.52),
                            AppColors.bg.withValues(alpha: 0.12),
                            AppColors.bg.withValues(alpha: 0.34),
                            AppColors.bg.withValues(alpha: 0.96),
                            AppColors.bg,
                          ]
                        : [
                            AppColors.bg.withValues(alpha: 0.24),
                            AppColors.bg.withValues(alpha: 0.04),
                            AppColors.bg.withValues(alpha: 0.78),
                            AppColors.bg,
                            AppColors.bg,
                          ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final diameter = isTv
                    ? (wide ? 160.0 : 120.0)
                    : (constraints.maxWidth >= 600 ? 112.0 : 100.0);
                final columns = isTv || wide ? 4 : 2;
                final gridWidth = math.min(
                  isTv || wide
                      ? (diameter + 32) * columns + 16 * (columns - 1)
                      : constraints.maxWidth - 32,
                  math.max(0.0, constraints.maxWidth - (wide ? 96 : 32)),
                );
                const topPadding = 24.0;
                final bottomPadding = math.max(
                  24.0,
                  MediaQuery.paddingOf(context).bottom + 16,
                );
                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(
                        0.0,
                        constraints.maxHeight -
                            topPadding -
                            (isTv ? bottomPadding : 0),
                      ),
                    ),
                    child: Container(
                      key: const ValueKey('profile-picker-bottom-content'),
                      width: math.min(
                        constraints.maxWidth,
                        isTv ? 1400.0 : 820.0,
                      ),
                      padding: EdgeInsets.fromLTRB(
                        16,
                        topPadding,
                        16,
                        bottomPadding,
                      ),
                      child: ValueListenableBuilder<int>(
                        valueListenable: _profiles.revision,
                        builder: (context, _, _) {
                          final lastName = _profiles.active.value?.name;
                          final title = FadeTransition(
                            key: const ValueKey('profile-picker-title-fade'),
                            opacity: _titleOpacity,
                            child: Column(
                              children: [
                                Text(
                                  "Who's watching?",
                                  textAlign: TextAlign.center,
                                  style: AppText.title.copyWith(
                                    fontSize: wide ? 34 : 28,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                Text(
                                  lastName == null
                                      ? 'Pick up where you left off.'
                                      : 'Ready for the next watch, $lastName?',
                                  textAlign: TextAlign.center,
                                  style: AppText.caption.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          );
                          final grid = _pickerGrid(
                            diameter: diameter,
                            gridWidth: gridWidth,
                            columns: columns,
                            isTv: isTv,
                            gapScale: isTv ? 0.5 : 1.0,
                          );
                          final manage = FadeTransition(
                            key: const ValueKey('profile-picker-footer-fade'),
                            opacity: _footerOpacity,
                            child: _manageProfilesButton(isTv),
                          );
                          if (isTv) {
                            return Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                title,
                                SizedBox(height: wide ? 28 : 16),
                                grid,
                                SizedBox(height: wide ? 16 : 8),
                                manage,
                              ],
                            );
                          }
                          return Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              title,
                              const SizedBox(height: 20),
                              grid,
                              const SizedBox(height: 16),
                              manage,
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
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
      icon: const Icon(Icons.edit_rounded, size: 18),
      label: const Text('Manage profiles'),
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: AppColors.hairline),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    );
  }

  Widget _pickerGrid({
    required double diameter,
    required double gridWidth,
    required int columns,
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
        crossAxisCount: columns,
        crossAxisSpacing: 4,
        mainAxisSpacing: 16,
        mainAxisExtent: diameter + 48,
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
              child: _profilePickerAction(
                title: 'Add',
                semanticLabel: 'Add profile',
                icon: Icons.add_rounded,
                diameter: diameter,
                isTv: isTv,
                autofocus: profiles.isEmpty,
                onTap: () => _edit(
                  null,
                  defaultAvatarForNewProfile(_profiles.profiles.length),
                ),
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
    final photo = profilePhotoForFace(
      profile: profile,
      accountPhotoUrl: _accountPhoto(),
    );

    Widget content(bool focused) => SizedBox(
      width: diameter + 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ProfileAvatarTapTarget(
            key: avatarKey,
            profileId: profile.id,
            diameter: diameter,
            fill: fill,
            shape: CircleBorder(
              side: BorderSide(
                color: AppColors.textPrimary.withValues(alpha: 0.25),
              ),
            ),
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

  Widget _profilePickerAction({
    required String title,
    required String semanticLabel,
    required IconData icon,
    required double diameter,
    required bool isTv,
    required bool autofocus,
    required VoidCallback onTap,
  }) {
    Widget content(bool focused) => SizedBox(
      width: diameter + 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            key: ValueKey('profile-picker-action-$title'),
            duration: const Duration(milliseconds: 180),
            width: diameter,
            height: diameter,
            decoration: BoxDecoration(
              color: AppColors.surface2,
              shape: BoxShape.circle,
              border: focused
                  ? Border.all(color: AppColors.accent, width: 2)
                  : Border.all(color: AppColors.hairline),
            ),
            child: Icon(
              icon,
              size: diameter * 0.38,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
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
        semanticLabel: semanticLabel,
        onTap: onTap,
        builder: content,
      );
    }
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
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
          photoUrl: profilePhotoForFace(
            profile: profile,
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
    required this.shape,
    required this.onTap,
    required this.child,
  });

  final String profileId;
  final double diameter;
  final Color fill;
  final ShapeBorder shape;
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
    dimension: widget.diameter,
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
          flightShuttleBuilder: (_, _, _, fromHeroContext, _) => FittedBox(
            key: const ValueKey('profile-flight-avatar'),
            fit: BoxFit.contain,
            child: (fromHeroContext.widget as Hero).child,
          ),
          child: Material(
            key: ValueKey('profile-avatar-fill-${widget.profileId}'),
            color: widget.fill,
            shape: widget.shape,
            clipBehavior: Clip.antiAlias,
            child: InkResponse(
              key: ValueKey('profile-avatar-ink-${widget.profileId}'),
              containedInkWell: true,
              highlightShape: BoxShape.circle,
              customBorder: widget.shape,
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
  );
}
