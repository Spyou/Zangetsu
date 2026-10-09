import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

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

/// Avatar a newly created profile starts with: spread across the icon set
/// by creation order so siblings never all look identical.
int defaultAvatarForNewProfile(int existingCount) =>
    existingCount % viewerProfileAvatarIcons.length;
