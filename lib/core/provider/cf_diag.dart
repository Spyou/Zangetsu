import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// TEMPORARY debug sink for the Cloudflare-detection investigation.
///
/// This device suppresses app logcat output, so `print` diagnostics never
/// reach a capture. Writing to the app's EXTERNAL files dir gives a file that
/// `adb pull` can read from a release build without root.
///
/// Remove once the Cloudflare-shield behaviour is confirmed on device.
class CfDiag {
  CfDiag._();

  static File? _f;
  static bool _tried = false;

  static Future<void> _open() async {
    if (_tried) return;
    _tried = true;
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;
      _f = File('${dir.path}/cfdiag.log');
      await _f!.writeAsString('--- cfdiag start ---\n', mode: FileMode.append);
    } catch (_) {
      _f = null;
    }
  }

  static void write(String line) {
    unawaited(() async {
      await _open();
      try {
        await _f?.writeAsString('$line\n', mode: FileMode.append);
      } catch (_) {}
    }());
  }
}
