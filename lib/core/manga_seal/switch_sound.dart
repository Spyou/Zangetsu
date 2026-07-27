import 'dart:io';

import 'package:dio/dio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../app_config.dart';
import '../di/injector.dart';

/// Plays the sealed-Manga "release" SFX. The clip is fetched from
/// [kSwitchSoundUrl] on first use and cached on-device (never bundled), so it
/// adds nothing to the APK. Reuses the app's media_kit stack — no new audio
/// dependency. Everything is best-effort: no clip, offline, or a playback
/// hiccup just means silence, never an error.
abstract final class SwitchSound {
  static Future<String?> _ensureFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final out = File('${dir.path}/manga_seal/switch.mp3');
      if (await out.exists() && await out.length() > 0) return out.path;
      await out.parent.create(recursive: true);
      final res = await sl<Dio>().get<List<int>>(
        kSwitchSoundUrl,
        options: Options(
          responseType: ResponseType.bytes,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (s) => s != null && s < 400,
        ),
      );
      final bytes = res.data;
      if (bytes == null || bytes.isEmpty) return null;
      await out.writeAsBytes(bytes);
      return out.path;
    } catch (_) {
      return null;
    }
  }

  /// Downloads-if-needed then plays the clip once. Fire-and-forget; the player
  /// self-disposes when playback finishes so we never leak an mpv instance.
  static Future<void> play() async {
    final path = await _ensureFile();
    if (path == null) return;
    final player = Player();
    player.stream.completed.listen((done) {
      if (done) player.dispose();
    });
    try {
      await player.open(Media(path));
    } catch (_) {
      await player.dispose();
    }
  }
}
