import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/profiles/viewer_profile.dart';
import 'package:watch_app/core/profiles/viewer_profile_avatar.dart';

void main() {
  testWidgets('decodes GIF avatars at their physical display size', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2),
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: ProfileAvatarFace(
            profile: ViewerProfile(id: 'test', name: 'Test'),
            photoUrl: 'https://cdn.example/avatar.gif?version=1',
            iconSize: 24,
            photoDiameter: 48,
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
    final resized = image.image as ResizeImage;
    expect(resized.width, 96);
    expect(resized.height, 96);
  });

  testWidgets('decodes normal photos at their physical display size', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2),
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: ProfileAvatarFace(
            profile: ViewerProfile(id: 'test', name: 'Test'),
            photoUrl: 'https://cdn.example/avatar.jpg',
            iconSize: 24,
            photoDiameter: 48,
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<ResizeImage>());
    final resized = image.image as ResizeImage;
    expect(resized.width, 96);
    expect(resized.height, 96);
  });
}
