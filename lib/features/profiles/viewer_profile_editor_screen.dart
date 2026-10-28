import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/profile_avatar_uploader.dart';
import '../../core/profiles/profile_lock_store.dart';
import 'profile_lock_gate.dart';
import '../../core/profiles/klipy_gif_service.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/supabase/supabase_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';
import '../auth/auth_cubit.dart';
import '../auth/auth_screens.dart' show requireLogin;
import 'klipy_gif_picker.dart';

Future<void> openViewerProfileEditor(
  BuildContext context,
  ViewerProfileStore profiles, {
  ViewerProfile? profile,
  int initialAvatar = 0,
}) async {
  final result = await Navigator.of(context).push<ProfileEditorResult>(
    MaterialPageRoute<ProfileEditorResult>(
      builder: (_) => ViewerProfileEditorScreen(
        profile: profile,
        initialAvatar: initialAvatar,
        klipyGifService: KlipyGifService.shared,
      ),
    ),
  );
  if (result == null) return;
  if (profile == null) {
    final created = await profiles.create(
      result.name,
      bio: result.bio,
      avatar: result.avatar,
      isKids: result.isKids,
      photoUrl: result.photoUrl,
      coverUrl: result.coverUrl,
    );
    if (created == null &&
        (result.photoUrl != null || result.coverUrl != null)) {
      final token =
          sl<SupabaseService>().client.auth.currentSession?.accessToken;
      if (token != null) {
        final uploader = ProfileAvatarUploader(sl<Dio>());
        for (final url in {
          result.photoUrl,
          result.coverUrl,
        }.whereType<String>()) {
          await uploader.delete(url: url, token: token);
        }
      }
    }
  } else {
    final auth = sl.isRegistered<AuthCubit>() ? sl<AuthCubit>() : null;
    final syncAccountName =
        profile.isDefault &&
        result.name != profile.name &&
        auth != null &&
        auth.state.isLoggedIn;
    final oldAccountName = auth?.state.displayName;
    if (syncAccountName && !await auth.updateName(result.name)) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Could not update account name')),
        );
      }
      return;
    }
    final renamed = await profiles.rename(profile.id, result.name);
    if (!renamed && syncAccountName) {
      await profiles.rename(profile.id, profile.name);
      final accountRestored =
          oldAccountName != null && await auth.updateName(oldAccountName);
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              accountRestored
                  ? 'Could not update profile name'
                  : 'Could not restore account name; check your connection',
            ),
          ),
        );
      }
      return;
    }
    final synced = await profiles.update(
      profile.id,
      bio: result.bio,
      avatar: result.avatar,
      isKids: result.isKids,
      photoUrl: result.photoUrl,
      clearPhotoUrl: result.photoUrl == null,
      coverUrl: result.coverUrl,
      clearCoverUrl: result.coverUrl == null,
    );
    if (!synced && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('Saved on this device; cloud sync will retry.'),
        ),
      );
    }
    if (synced &&
        profile.photoUrl != null &&
        profile.photoUrl != result.photoUrl &&
        !profiles.profiles.any(
          (other) =>
              other.id != profile.id && other.photoUrl == profile.photoUrl,
        )) {
      final token =
          sl<SupabaseService>().client.auth.currentSession?.accessToken;
      if (token != null) {
        await ProfileAvatarUploader(
          sl<Dio>(),
        ).delete(url: profile.photoUrl!, token: token);
      }
    }
    if (synced &&
        profile.coverUrl != null &&
        profile.coverUrl != result.coverUrl &&
        !profiles.profiles.any(
          (other) =>
              other.id != profile.id &&
              (other.coverUrl == profile.coverUrl ||
                  other.photoUrl == profile.coverUrl),
        )) {
      final token =
          sl<SupabaseService>().client.auth.currentSession?.accessToken;
      if (token != null) {
        await ProfileAvatarUploader(
          sl<Dio>(),
        ).delete(url: profile.coverUrl!, token: token);
      }
    }
  }
}

class ProfileEditorResult {
  const ProfileEditorResult({
    required this.name,
    required this.bio,
    required this.avatar,
    required this.isKids,
    this.photoUrl,
    this.coverUrl,
  });

  final String name;
  final String bio;
  final int avatar;
  final bool isKids;
  final String? photoUrl;
  final String? coverUrl;
}

enum _PhotoSource { gallery, fileGif, klipy }

class ViewerProfileEditorScreen extends StatefulWidget {
  const ViewerProfileEditorScreen({
    super.key,
    this.profile,
    this.initialAvatar = 0,
    this.klipyGifService,
  });

  final ViewerProfile? profile;
  final int initialAvatar;
  final KlipyGifService? klipyGifService;

  @override
  State<ViewerProfileEditorScreen> createState() =>
      _ViewerProfileEditorScreenState();
}

class _ViewerProfileEditorScreenState extends State<ViewerProfileEditorScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.profile?.name ?? '',
  );
  late final TextEditingController _bio = TextEditingController(
    text: widget.profile?.bio ?? '',
  );
  late final int _avatar = widget.profile?.avatar ?? widget.initialAvatar;
  late bool _isKids = widget.profile?.isKids ?? false;
  late String? _photoUrl = widget.profile?.photoUrl;
  late String? _coverUrl = widget.profile?.coverUrl;
  bool _uploading = false;
  bool _locked = false;
  String? _photoError;
  String? _coverError;
  final _uploadedUrls = <String>{};
  String? _uploadToken;
  bool _saved = false;

  ProfileLockStore? get _locks =>
      sl.isRegistered<ProfileLockStore>() ? sl<ProfileLockStore>() : null;

  @override
  void initState() {
    super.initState();
    final id = widget.profile?.id;
    final locks = _locks;
    if (id != null && locks != null) {
      locks
          .isLocked(id)
          .then(
            (v) {
              if (mounted) setState(() => _locked = v);
            },
            onError: (Object error) {
              if (mounted) setState(() => _locked = true);
            },
          );
    }
  }

  Future<void> _manageLock() async {
    final profile = widget.profile;
    final locks = _locks;
    if (profile == null || locks == null) return;
    final result = await manageProfilePin(
      context,
      profileId: profile.id,
      profileName: profile.name,
      locks: locks,
    );
    if (result != null && mounted) setState(() => _locked = result);
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty &&
      _bio.text.trim().runes.length <= ViewerProfileStore.maxBioLength &&
      !_uploading;

  @override
  void dispose() {
    final token = _uploadToken;
    if (token != null) {
      for (final url in _uploadedUrls) {
        if (_saved && (url == _photoUrl || url == _coverUrl)) continue;
        unawaited(
          ProfileAvatarUploader(sl<Dio>()).delete(url: url, token: token),
        );
      }
    }
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    if (!requireLogin(context, action: 'change a profile avatar')) return;
    final source = await showModalBottomSheet<_PhotoSource>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
                child: Text('Choose avatar', style: AppText.title),
              ),
              ListTile(
                tileColor: AppColors.surface2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                leading: Icon(Icons.photo_outlined, color: AppColors.accent),
                title: const Text('Photo from gallery'),
                subtitle: const Text('Choose an image on this device'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_PhotoSource.gallery),
              ),
              const SizedBox(height: 8),
              ListTile(
                tileColor: AppColors.surface2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                leading: Icon(
                  Icons.movie_filter_outlined,
                  color: AppColors.accent,
                ),
                title: const Text('Animated GIF file'),
                subtitle: const Text('Choose a GIF on this device'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_PhotoSource.fileGif),
              ),
              const SizedBox(height: 8),
              ListTile(
                tileColor: AppColors.surface2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                leading: Icon(Icons.search_rounded, color: AppColors.accent),
                title: const Text('Search GIFs'),
                subtitle: const Text('Find an animated avatar online'),
                onTap: () => Navigator.of(sheetContext).pop(_PhotoSource.klipy),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;
    if (source == _PhotoSource.fileGif) {
      await _pickGif();
      return;
    }
    if (source == _PhotoSource.klipy) {
      final service = widget.klipyGifService ?? KlipyGifService.shared;
      final gif = await showProfileKlipyGifPicker(context, service);
      if (gif == null || !mounted) return;
      setState(() {
        _photoUrl = gif.avatarUrl;
        _photoError = null;
      });
      return;
    }
    await _pickStillPhoto();
  }

  Future<void> _pickStillPhoto() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: ProfileAvatarUploader.maxAvatarDimension.toDouble(),
      maxHeight: ProfileAvatarUploader.maxAvatarDimension.toDouble(),
      imageQuality: 100,
    );
    if (x == null || !mounted) return;
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    await _uploadAvatarBytes(bytes);
  }

  Future<void> _pickGif() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['gif'],
      );
      if (file == null || !mounted) return;
      final size = await file.length();
      if (!mounted) return;
      if (size > ProfileAvatarUploader.maxGifSourceBytes) {
        setState(
          () => _photoError =
              'This GIF is too large to optimize safely. Try a smaller file.',
        );
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      await _uploadAvatarBytes(
        bytes,
        failureMessage:
            'Couldn’t process or upload this GIF. Try a smaller file or check your connection.',
      );
    } catch (_) {
      if (mounted) {
        setState(() => _photoError = 'Could not read that GIF file.');
      }
    }
  }

  Future<void> _uploadAvatarBytes(
    Uint8List bytes, {
    String failureMessage = "Couldn't upload photo",
  }) async {
    if (!requireLogin(context, action: 'upload a profile avatar')) return;
    final token = sl<SupabaseService>().client.auth.currentSession?.accessToken;
    if (token == null) {
      setState(() => _photoError = failureMessage);
      return;
    }
    setState(() {
      _uploading = true;
      _photoError = null;
    });
    String? url;
    try {
      url = await ProfileAvatarUploader(
        sl<Dio>(),
      ).upload(bytes: bytes, token: token);
    } catch (_) {
      url = null;
    }
    if (!mounted) {
      if (url != null) {
        unawaited(
          ProfileAvatarUploader(sl<Dio>()).delete(url: url, token: token),
        );
      }
      return;
    }
    setState(() {
      _uploading = false;
      if (url != null) {
        _uploadToken = token;
        _uploadedUrls.add(url);
        _photoUrl = url;
      } else {
        _photoError = failureMessage;
      }
    });
  }

  Future<void> _pickCover() async {
    if (!requireLogin(context, action: 'upload a profile cover')) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      maxHeight: 900,
      imageQuality: 100,
    );
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    if (!requireLogin(context, action: 'upload a profile cover')) return;
    final token = sl<SupabaseService>().client.auth.currentSession?.accessToken;
    if (token == null) {
      setState(() => _coverError = 'Sign in to upload a cover');
      return;
    }
    setState(() {
      _uploading = true;
      _coverError = null;
    });
    final url = await ProfileAvatarUploader(
      sl<Dio>(),
    ).uploadCover(bytes: bytes, token: token);
    if (!mounted) {
      if (url != null) {
        unawaited(
          ProfileAvatarUploader(sl<Dio>()).delete(url: url, token: token),
        );
      }
      return;
    }
    setState(() {
      _uploading = false;
      if (url != null) {
        _uploadToken = token;
        _uploadedUrls.add(url);
        _coverUrl = url;
      } else {
        _coverError = "Couldn't upload cover. Try another image.";
      }
    });
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty || _uploading) return;
    _saved = true;
    Navigator.of(context).pop(
      ProfileEditorResult(
        name: name,
        bio: _bio.text.trim(),
        avatar: _avatar,
        isKids: _isKids,
        photoUrl: _photoUrl,
        coverUrl: _coverUrl,
      ),
    );
  }

  Widget _editorCard(String keyName, Widget child) => Card(
    key: ValueKey(keyName),
    margin: EdgeInsets.zero,
    color: AppColors.settingsCard,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(26),
      side: const BorderSide(color: AppColors.hairline),
    ),
    child: Padding(padding: const EdgeInsets.all(18), child: child),
  );

  InputDecoration _fieldDecoration({
    required String label,
    String? hint,
    String? errorText,
  }) => InputDecoration(
    labelText: label,
    hintText: hint,
    errorText: errorText,
    filled: true,
    fillColor: AppColors.bg,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: BorderSide(color: AppColors.hairline),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: BorderSide(color: AppColors.hairline),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(20),
      borderSide: BorderSide(color: AppColors.accent, width: 1.5),
    ),
    counterStyle: AppText.caption,
  );

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final previewProfile = ViewerProfile(
      id: profile?.id ?? 'new-profile-preview',
      name: _name.text,
      avatar: _avatar,
      isKids: _isKids,
      photoUrl: _photoUrl,
    );
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: settingsAppBar(
        profile == null ? 'Add profile' : 'Edit profile',
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: FilledButton.tonal(
              onPressed: _canSave ? _save : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size(64, 40),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              MediaQuery.viewInsetsOf(context).bottom + 24,
            ),
            children: [
              _editorCard(
                'profile-editor-form-card',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        SizedBox.square(
                          dimension: 76,
                          child: CircleAvatar(
                            backgroundColor: viewerProfileAvatarColor(_avatar),
                            child: ProfileAvatarFace(
                              profile: previewProfile,
                              photoUrl: _photoUrl,
                              iconSize: 36,
                              photoDiameter: 70,
                              klipyGifService: widget.klipyGifService,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Profile avatar',
                                style: AppText.caption.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _name.text.trim().isEmpty
                                    ? 'New profile'
                                    : _name.text.trim(),
                                key: const ValueKey(
                                  'profile-editor-preview-name',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.title,
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  FilledButton.tonalIcon(
                                    onPressed: _uploading ? null : _pickPhoto,
                                    icon: _uploading
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.photo_outlined,
                                            size: 18,
                                          ),
                                    label: Text(
                                      _uploading
                                          ? 'Uploading…'
                                          : _photoUrl == null
                                          ? 'Choose avatar'
                                          : 'Change avatar',
                                    ),
                                  ),
                                  if (_photoUrl != null)
                                    IconButton.filledTonal(
                                      tooltip: 'Remove avatar',
                                      onPressed: _uploading
                                          ? null
                                          : () => setState(
                                              () => _photoUrl = null,
                                            ),
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18,
                                      ),
                                    ),
                                ],
                              ),
                              if (_photoError != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  _photoError!,
                                  style: AppText.caption.copyWith(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      key: const ValueKey('profile-editor-name'),
                      controller: _name,
                      maxLength: ViewerProfileStore.maxNameLength,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      onChanged: (_) => setState(() {}),
                      decoration: _fieldDecoration(label: 'Name'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('profile-editor-bio'),
                      controller: _bio,
                      maxLength: ViewerProfileStore.maxBioLength,
                      maxLines: 3,
                      minLines: 2,
                      onChanged: (_) => setState(() {}),
                      textCapitalization: TextCapitalization.sentences,
                      decoration: _fieldDecoration(
                        label: 'Bio',
                        hint: 'Add a short bio',
                        errorText:
                            _bio.text.trim().runes.length >
                                ViewerProfileStore.maxBioLength
                            ? 'Bio is too long'
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _editorCard(
                'profile-editor-cover-card',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Profile cover', style: AppText.headline),
                              const SizedBox(height: 2),
                              Text(
                                'Optional image for your profile',
                                style: AppText.caption.copyWith(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.image_outlined,
                          color: AppColors.textSecondary,
                        ),
                      ],
                    ),
                    if (_coverUrl != null) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: AspectRatio(
                          aspectRatio: 2.7,
                          child: CachedNetworkImage(
                            imageUrl: _coverUrl!,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) =>
                                ColoredBox(color: AppColors.accentSoft),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: _uploading ? null : _pickCover,
                          icon: const Icon(
                            Icons.photo_library_outlined,
                            size: 18,
                          ),
                          label: Text(
                            _coverUrl == null ? 'Add cover' : 'Change cover',
                          ),
                        ),
                        if (_coverUrl != null)
                          TextButton.icon(
                            onPressed: _uploading
                                ? null
                                : () => setState(() => _coverUrl = null),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                            ),
                            label: const Text('Remove cover'),
                          ),
                      ],
                    ),
                    if (_coverError != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _coverError!,
                        style: AppText.caption.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SettingsCard(
                key: const ValueKey('profile-editor-kids-card'),
                margin: EdgeInsets.zero,
                children: [
                  SettingsTile(
                    icon: Icons.child_care_rounded,
                    title: 'Kids profile',
                    subtitle: 'Hide adult-rated catalogue titles',
                    trailing: Switch.adaptive(
                      value: _isKids,
                      onChanged: (value) => setState(() => _isKids = value),
                    ),
                    onTap: () => setState(() => _isKids = !_isKids),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SettingsCard(
                margin: EdgeInsets.zero,
                children: [
                  SettingsTile(
                    icon: Icons.lock_rounded,
                    title: 'Profile lock',
                    subtitle: _locked
                        ? 'PIN required to open this profile'
                        : 'Ask for a PIN before opening this profile',
                    trailing: Icon(
                      _locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                      color: _locked
                          ? AppColors.accent
                          : AppColors.textTertiary,
                    ),
                    onTap: _manageLock,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Kids profiles hide adult-rated catalogue titles only when ratings are available. This is not a parental lock.',
                  style: AppText.caption.copyWith(
                    color: AppColors.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
