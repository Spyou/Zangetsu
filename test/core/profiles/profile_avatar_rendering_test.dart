import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:watch_app/core/profiles/klipy_gif_service.dart';
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

  testWidgets('loads legacy KLIPY slug avatars through the app image cache', (
    tester,
  ) async {
    final service = _KlipyAvatarUrlService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileAvatarFace(
            profile: const ViewerProfile(
              id: 'test',
              name: 'Test',
              photoUrl: 'klipy:zoro-wave',
            ),
            photoUrl: 'klipy:zoro-wave',
            iconSize: 24,
            photoDiameter: 48,
            klipyGifService: service,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    expect(resized.imageProvider, isA<CachedNetworkImageProvider>());
    expect(
      (resized.imageProvider as CachedNetworkImageProvider).url,
      'https://static.klipy.com/zoro-avatar.gif',
    );
  });

  testWidgets('loads a saved KLIPY media URL through the app image cache', (
    tester,
  ) async {
    const url = 'https://static.klipy.com/zoro-avatar.gif';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ProfileAvatarFace(
            profile: ViewerProfile(id: 'test', name: 'Test', photoUrl: url),
            photoUrl: url,
            iconSize: 24,
            photoDiameter: 48,
          ),
        ),
      ),
    );

    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    expect(resized.imageProvider, isA<CachedNetworkImageProvider>());
    expect((resized.imageProvider as CachedNetworkImageProvider).url, url);
  });
}

class _KlipyAvatarUrlService extends KlipyGifService {
  _KlipyAvatarUrlService()
    : super(
        Dio(),
        baseUrl: 'https://sync.AniAura.online/klipy/v1',
        accessToken: () => 'test-access-token',
      );

  @override
  Future<String?> avatarUrlForSlug(String slug) async =>
      slug == 'zoro-wave' ? 'https://static.klipy.com/zoro-avatar.gif' : null;
}
