import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

void main() {
  late Directory tempDir;
  late PlaybackPrefs prefs;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tv_decoder_mode_test');
    Hive.init(tempDir.path);
    await PlaybackPrefs.init();
    prefs = PlaybackPrefs();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  group('TV decoder mode persistence', () {
    test('explicit legacy hardware-only selection is preserved', () async {
      await Hive.box(PlaybackPrefs.boxName).put('tvSoftwareDecoding', false);
      expect(prefs.tvDecoderMode, TvDecoderMode.hardwareOnly);
    });

    test(
      'all saved TV choices survive without changing mobile decoder',
      () async {
        final mobileDecoder = prefs.videoDecoder;
        for (final mode in TvDecoderMode.values) {
          await prefs.setTvDecoderMode(mode);
          expect(PlaybackPrefs().tvDecoderMode, mode);
          expect(prefs.videoDecoder, mobileDecoder);
        }
      },
    );

    test('uses stable native-player values for the three choices', () {
      expect(TvDecoderMode.hardwareOnly.wireValue, 0);
      expect(TvDecoderMode.hardwareFirst.wireValue, 1);
      expect(TvDecoderMode.softwareFirst.wireValue, 2);
    });

    test('restores a saved mode before consulting the legacy toggle', () {
      expect(
        TvDecoderMode.fromStorage(2, legacySoftwareDecoding: false),
        TvDecoderMode.softwareFirst,
      );
    });

    test(
      'maps legacy software decoding to the old hardware-first behavior',
      () {
        expect(
          TvDecoderMode.fromStorage(null, legacySoftwareDecoding: true),
          TvDecoderMode.hardwareFirst,
        );
        expect(
          TvDecoderMode.fromStorage(null, legacySoftwareDecoding: false),
          TvDecoderMode.hardwareOnly,
        );
      },
    );

    test('unknown persisted values safely use the legacy setting', () {
      expect(
        TvDecoderMode.fromStorage(99, legacySoftwareDecoding: true),
        TvDecoderMode.hardwareFirst,
      );
    });

    test(
      'PlaybackPrefs reads legacy choice and persists the new mode',
      () async {
        expect(prefs.tvDecoderMode, TvDecoderMode.hardwareFirst);

        await Hive.box(PlaybackPrefs.boxName).put('tvSoftwareDecoding', true);
        expect(prefs.tvDecoderMode, TvDecoderMode.hardwareFirst);

        await prefs.setTvDecoderMode(TvDecoderMode.softwareFirst);
        expect(prefs.tvDecoderMode, TvDecoderMode.softwareFirst);
        expect(
          Hive.box(PlaybackPrefs.boxName).get('tvDecoderMode'),
          TvDecoderMode.softwareFirst.wireValue,
        );
        expect(
          Hive.box(PlaybackPrefs.boxName).get('tvSoftwareDecoding'),
          isTrue,
        );
      },
    );
  });
}
