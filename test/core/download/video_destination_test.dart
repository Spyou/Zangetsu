import 'package:flutter_test/flutter_test.dart';
import 'package:watch_app/core/download/video_destination.dart';

void main() {
  group('videoDestination', () {
    test('keepPrivate wins over everything', () {
      expect(
        videoDestination(
          keepPrivate: true,
          locationUri: 'content://tree/primary%3ADownloads',
        ),
        VideoDestination.privateStorage,
      );
      expect(
        videoDestination(keepPrivate: true, locationUri: '/storage/1234-ABCD'),
        VideoDestination.privateStorage,
      );
      expect(
        videoDestination(keepPrivate: true, locationUri: null),
        VideoDestination.privateStorage,
      );
    });

    test('no location and no toggle means public Downloads', () {
      expect(
        videoDestination(keepPrivate: false, locationUri: null),
        VideoDestination.publicDownloads,
      );
      expect(
        videoDestination(keepPrivate: false, locationUri: ''),
        VideoDestination.publicDownloads,
      );
    });

    test('a content:// location is a SAF tree', () {
      expect(
        videoDestination(
          keepPrivate: false,
          locationUri: 'content://tree/primary%3AMovies',
        ),
        VideoDestination.safTree,
      );
    });

    test('a plain path location is a detected drive', () {
      expect(
        videoDestination(keepPrivate: false, locationUri: '/storage/1234-ABCD'),
        VideoDestination.detectedVolume,
      );
    });
  });
}
