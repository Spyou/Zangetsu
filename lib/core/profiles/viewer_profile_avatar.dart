import 'package:flutter/material.dart';

import '../cache/app_image_cache.dart';
import '../ui/image_fade.dart';
import 'klipy_gif_service.dart';
import 'profile_avatar_reference.dart';
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

/// Flat neutral fill behind every avatar glyph/photo. Fixed, not tied to
/// Material You tones, so the border ring always reads against it.
const viewerProfileAvatarFill = Color(0xFF23262B);

IconData viewerProfileAvatarIcon(int avatar) =>
    viewerProfileAvatarIcons[avatar.clamp(
      0,
      viewerProfileAvatarIcons.length - 1,
    )];

Color viewerProfileAvatarColor(int avatar) => viewerProfileAvatarFill;

String viewerProfileHeroTag(String profileId) => 'viewer-profile-$profileId';

/// Use a profile's own photo first; the account photo is only the default
/// profile's fallback. A missing URL lets [ProfileAvatarFace] show its icon.
String? profilePhotoForFace({
  required ViewerProfile profile,
  required String? accountPhotoUrl,
}) {
  final profilePhoto = profile.photoUrl;
  if (profilePhoto != null && profilePhoto.isNotEmpty) return profilePhoto;
  return profile.isDefault ? accountPhotoUrl : null;
}

/// Icon or account photo. Photos are circular by default; the launch picker
/// can opt into rounded-square crops. Failed photos fall back to the icon.
class ProfileAvatarFace extends StatelessWidget {
  const ProfileAvatarFace({
    super.key,
    required this.profile,
    this.photoUrl,
    required this.iconSize,
    required this.photoDiameter,
    this.photoBorderRadius,
    this.klipyGifService,
  });

  final ViewerProfile profile;
  final String? photoUrl;
  final double iconSize;
  final double photoDiameter;
  final BorderRadius? photoBorderRadius;
  final KlipyGifService? klipyGifService;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      viewerProfileAvatarIcon(profile.avatar),
      size: iconSize,
      color: Colors.white,
    );
    final url = photoUrl;
    if (url == null || url.isEmpty) return icon;
    if (isKlipyAvatarReference(url)) {
      final slug = klipyAvatarSlug(url);
      if (slug == null) return icon;
      return FutureBuilder<String?>(
        future: (klipyGifService ?? KlipyGifService.shared).avatarUrlForSlug(
          slug,
        ),
        builder: (context, snapshot) => snapshot.data == null
            ? icon
            : _photo(context, icon, snapshot.data!),
      );
    }
    return _photo(context, icon, url);
  }

  Widget _photo(BuildContext context, Widget icon, String url) {
    final decodeSize =
        (photoDiameter * (MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1))
            .round();
    final image = Image(
      image: ResizeImage(
        AppImageCache.imageProvider(url),
        width: decodeSize,
        height: decodeSize,
        policy: ResizeImagePolicy.fit,
      ),
      fit: BoxFit.cover,
      filterQuality: FilterQuality.high,
      frameBuilder: imageFadeIn,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
    return SizedBox.square(
      dimension: photoDiameter,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(child: icon),
          if (photoBorderRadius == null)
            ClipOval(child: image)
          else
            ClipRRect(borderRadius: photoBorderRadius!, child: image),
        ],
      ),
    );
  }
}

/// Avatar a newly created profile starts with: spread across the icon set
/// by creation order so siblings never all look identical.
int defaultAvatarForNewProfile(int existingCount) =>
    existingCount % viewerProfileAvatarIcons.length;
