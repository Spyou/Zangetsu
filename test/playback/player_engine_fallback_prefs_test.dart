import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:watch_app/core/playback/playback_prefs.dart';

void main() {
  test(
    'fallback is opt-in, persists, and leaves playback preferences alone',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'engine_fallback_prefs',
      );
      Hive.init(dir.path);
      try {
        await PlaybackPrefs.init();
        final prefs = PlaybackPrefs();
        final player = prefs.externalPlayerPackage;
        final quality = prefs.defaultQuality;
        final decoder = prefs.videoDecoder;
        expect(prefs.autoPlayerFallback, isFalse);
        await prefs.setAutoPlayerFallback(true);
        expect(PlaybackPrefs().autoPlayerFallback, isTrue);
        expect(prefs.externalPlayerPackage, player);
        expect(prefs.defaultQuality, quality);
        expect(prefs.videoDecoder, decoder);
        await prefs.setAutoPlayerFallback(false);
        expect(prefs.autoPlayerFallback, isFalse);
      } finally {
        await Hive.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
