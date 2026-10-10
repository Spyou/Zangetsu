import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/di/injector.dart';
import '../../core/profiles/profile_avatar_uploader.dart';
import '../../core/profiles/viewer_profile.dart';
import '../../core/profiles/viewer_profile_avatar.dart';
import '../../core/supabase/supabase_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text.dart';
import '../../core/ui/settings_widgets.dart';

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
      ),
    ),
  );
  if (result == null) return;
  if (profile == null) {
    final created = await profiles.create(
      result.name,
      avatar: result.avatar,
      isKids: result.isKids,
      photoUrl: result.photoUrl,
    );
    if (created == null && result.photoUrl != null) {
      final token =
          sl<SupabaseService>().client.auth.currentSession?.accessToken;
      if (token != null) {
        await ProfileAvatarUploader(
          sl<Dio>(),
        ).delete(url: result.photoUrl!, token: token);
      }
    }
  } else {
    await profiles.rename(profile.id, result.name);
    final synced = await profiles.update(
      profile.id,
      avatar: result.avatar,
      isKids: result.isKids,
      photoUrl: result.photoUrl,
    );
    if (synced &&
        profile.photoUrl != null &&
        profile.photoUrl != result.photoUrl) {
      final token =
          sl<SupabaseService>().client.auth.currentSession?.accessToken;
      if (token != null) {
        await ProfileAvatarUploader(
          sl<Dio>(),
        ).delete(url: profile.photoUrl!, token: token);
      }
    }
  }
}

class ProfileEditorResult {
  const ProfileEditorResult({
    required this.name,
    required this.avatar,
    required this.isKids,
    this.photoUrl,
  });

  final String name;
  final int avatar;
  final bool isKids;
  final String? photoUrl;
}

class ViewerProfileEditorScreen extends StatefulWidget {
  const ViewerProfileEditorScreen({
    super.key,
    this.profile,
    this.initialAvatar = 0,
  });

  final ViewerProfile? profile;
  final int initialAvatar;

  @override
  State<ViewerProfileEditorScreen> createState() =>
      _ViewerProfileEditorScreenState();
}

class _ViewerProfileEditorScreenState extends State<ViewerProfileEditorScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.profile?.name ?? '',
  );
  late int _avatar = widget.profile?.avatar ?? widget.initialAvatar;
  late bool _isKids = widget.profile?.isKids ?? false;
  late String? _photoUrl = widget.profile?.photoUrl;
  bool _uploading = false;
  String? _photoError;
  final _uploadedUrls = <String>{};
  String? _uploadToken;
  bool _saved = false;

  bool get _canSave => _name.text.trim().isNotEmpty && !_uploading;

  @override
  void dispose() {
    final token = _uploadToken;
    if (token != null) {
      for (final url in _uploadedUrls) {
        if (_saved && url == _photoUrl) continue;
        unawaited(
          ProfileAvatarUploader(sl<Dio>()).delete(url: url, token: token),
        );
      }
    }
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 90,
    );
    if (x == null || !mounted) return;
    final token = sl<SupabaseService>().client.auth.currentSession?.accessToken;
    if (token == null) {
      setState(() => _photoError = "Couldn't upload photo");
      return;
    }
    setState(() {
      _uploading = true;
      _photoError = null;
    });
    String? url;
    try {
      final bytes = await x.readAsBytes();
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
        _photoError = "Couldn't upload photo";
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
        avatar: _avatar,
        isKids: _isKids,
        photoUrl: _photoUrl,
      ),
    );
  }

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
          TextButton(
            onPressed: _canSave ? _save : null,
            child: const Text('Save'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 28,
            ),
            children: [
              Center(
                child: Container(
                  width: 96,
                  height: 96,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.accent, width: 2.5),
                  ),
                  child: CircleAvatar(
                    radius: 44,
                    backgroundColor: viewerProfileAvatarColor(_avatar),
                    child: ProfileAvatarFace(
                      profile: previewProfile,
                      photoUrl: _photoUrl,
                      iconSize: 40,
                      photoDiameter: 88,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: OutlinedButton.icon(
                  onPressed: _uploading ? null : _pickPhoto,
                  icon: _uploading
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.photo_outlined, size: 18),
                  label: Text(_uploading ? 'Uploading…' : 'Choose photo'),
                ),
              ),
              if (_photoError != null) ...[
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    _photoError!,
                    style: AppText.caption.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              Text('Profile name', style: AppText.headline),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                maxLength: ViewerProfileStore.maxNameLength,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _canSave ? _save() : null,
                decoration: InputDecoration(
                  hintText: 'Name',
                  filled: true,
                  fillColor: AppColors.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide.none,
                  ),
                  counterStyle: AppText.caption,
                ),
              ),
              const SizedBox(height: 22),
              Text('Choose an avatar', style: AppText.headline),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < viewerProfileAvatarIcons.length; i++)
                    IconButton.filledTonal(
                      key: ValueKey('profile-editor-avatar-$i'),
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
              const SizedBox(height: 18),
              SettingsCard(
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
              Text(
                'Kids profiles hide adult-rated catalogue titles only when ratings are available. This is not a parental lock.',
                style: AppText.caption.copyWith(color: AppColors.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
