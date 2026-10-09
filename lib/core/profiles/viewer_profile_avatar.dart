import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'viewer_profile.dart';

const viewerProfileAvatarIcons = <IconData>[
  Icons.person_rounded,
  Icons.face_rounded,
  Icons.child_care_rounded,
  Icons.pets_rounded,
  Icons.rocket_launch_rounded,
  Icons.star_rounded,
  Icons.sports_esports_rounded,
  Icons.palette_rounded,
  Icons.music_note_rounded,
  Icons.favorite_rounded,
  Icons.movie_rounded,
  Icons.book_rounded,
];

const _avatarColors = <Color>[
  Color(0xFF408CFF),
  Color(0xFF8D63D6),
  Color(0xFF2EAA87),
  Color(0xFFE58A37),
  Color(0xFFE65D7A),
];

IconData viewerProfileAvatarIcon(int avatar) =>
    viewerProfileAvatarIcons[avatar.clamp(
      0,
      viewerProfileAvatarIcons.length - 1,
    )];

Color viewerProfileAvatarColor(int avatar) => avatar == 0
    ? AppColors.accent
    : _avatarColors[(avatar - 1) % _avatarColors.length];

String viewerProfileHeroTag(String profileId) => 'viewer-profile-$profileId';

/// The account photo belongs to the default (owner) profile only. Every
/// other profile keeps its icon, and a missing photo falls back to icons.
String? accountPhotoForProfile({
  required bool isDefault,
  required String? accountPhotoUrl,
}) => isDefault ? accountPhotoUrl : null;

/// Icon or account photo, drawn inside the caller's own circle. A photo
/// that fails to load falls back to the icon instead of an empty disc.
class ProfileAvatarFace extends StatelessWidget {
  const ProfileAvatarFace({
    super.key,
    required this.profile,
    this.photoUrl,
    required this.iconSize,
    required this.photoDiameter,
  });

  final ViewerProfile profile;
  final String? photoUrl;
  final double iconSize;
  final double photoDiameter;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      viewerProfileAvatarIcon(profile.avatar),
      size: iconSize,
      color: Colors.white,
    );
    final url = photoUrl;
    if (url == null || url.isEmpty) return icon;
    return ClipOval(
      child: Image.network(
        url,
        width: photoDiameter,
        height: photoDiameter,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => icon,
      ),
    );
  }
}

/// Avatar a newly created profile starts with: spread across the icon set
/// by creation order so siblings never all look identical.
int defaultAvatarForNewProfile(int existingCount) =>
    existingCount % viewerProfileAvatarIcons.length;
