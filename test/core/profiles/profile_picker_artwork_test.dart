import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/profiles/profile_picker_artwork.dart';

void main() {
  late Directory directory;
  late Box box;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('profile_picker_art');
    Hive.init(directory.path);
    box = await Hive.openBox('profile_picker_art');
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('rotates through at most three safe image names', () async {
    final artwork = ProfilePickerArtwork(
      box: box,
      fetchManifest: () async => {
        'images': [
          'one.webp',
          '../outside.webp',
          'script.svg',
          'two.jpg',
          'three.png',
          'four.webp',
        ],
      },
    );

    final first = await artwork.next();
    final second = await artwork.next();
    final third = await artwork.next();
    final wrapped = await artwork.next();

    expect(first, endsWith('/profile-picker/one.webp'));
    expect(second, endsWith('/profile-picker/two.jpg'));
    expect(third, endsWith('/profile-picker/three.png'));
    expect(wrapped, first);
    expect(artwork.cachedUrl, first);
  });

  test('keeps the first image cached while the picker rotates', () async {
    final artwork = ProfilePickerArtwork(
      box: box,
      fetchManifest: () async => {
        'images': ['one.webp', 'two.webp', 'three.webp'],
      },
    );

    final first = await artwork.next();
    await artwork.next();

    expect(artwork.cachedUrl, first);
  });

  test('fetches the manifest once while cycling images', () async {
    var fetches = 0;
    final artwork = ProfilePickerArtwork(
      box: box,
      fetchManifest: () async {
        fetches++;
        return {
          'images': ['one.webp', 'two.webp', 'three.webp'],
        };
      },
    );

    await artwork.next();
    await artwork.next();
    await artwork.next();
    await artwork.next();

    expect(fetches, 1);
  });

  test('starts with the first image on each new picker session', () async {
    await box.put(
      ProfilePickerArtwork.lastUrlKey,
      'https://pub-a8b67f6edb404cb1b7545e19bc2b5b94.r2.dev/profile-picker/two.webp',
    );
    final artwork = ProfilePickerArtwork(
      box: box,
      fetchManifest: () async => {
        'images': ['one.webp', 'two.webp', 'three.webp'],
      },
    );

    expect(await artwork.next(), endsWith('/profile-picker/one.webp'));
    expect(await artwork.next(), endsWith('/profile-picker/two.webp'));
  });

  test(
    'retains the last valid backdrop if the manifest is unavailable',
    () async {
      const cachedUrl =
          'https://pub-a8b67f6edb404cb1b7545e19bc2b5b94.r2.dev/profile-picker/cached.webp';
      var fetches = 0;
      await box.put(ProfilePickerArtwork.lastUrlKey, cachedUrl);
      final artwork = ProfilePickerArtwork(
        box: box,
        fetchManifest: () async {
          fetches++;
          throw const SocketException('offline');
        },
      );

      expect(await artwork.next(), cachedUrl);
      expect(await artwork.next(), cachedUrl);
      expect(fetches, 1);
    },
  );

  test('ignores cached image URLs outside the public art path', () async {
    await box.put(
      ProfilePickerArtwork.lastUrlKey,
      'https://other.example/profile-picker/image.webp',
    );
    final artwork = ProfilePickerArtwork(
      box: box,
      fetchManifest: () async => {'images': []},
    );

    expect(artwork.cachedUrl, isNull);
    expect(await artwork.next(), isNull);
  });
}
