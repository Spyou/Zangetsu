import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'tv_track_helpers.dart' show subtitleFontAsset, subtitleFontFileName;

/// Copies / locates a subtitle font under `<appSupport>/sub_fonts/` so native
/// TV players can `Typeface.createFromFile` it.
///
/// Callers must [SubtitleFontService.ensure] download-on-demand families first.
/// Bundled APK fonts (Inter, Noto Sans) are copied from assets here.
/// Returns null for Default ('') or when the file is missing.
Future<String?> stageSubtitleFont(String family) async {
  if (family.isEmpty) return null;

  final dir = Directory(
    '${(await getApplicationSupportDirectory()).path}/sub_fonts',
  );
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final asset = subtitleFontAsset(family);
  if (asset != null) {
    // Bundled in the APK — copy from assets once.
    try {
      final out = File('${dir.path}/${asset.split('/').last}');
      if (!await out.exists()) {
        final bytes = await rootBundle.load(asset);
        await out.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      }
      return out.path;
    } catch (_) {
      return null;
    }
  }

  // Download-on-demand: already ensured into this folder by the caller.
  final fname = subtitleFontFileName(family);
  if (fname == null) return null;
  final f = File('${dir.path}/$fname');
  return f.existsSync() ? f.path : null;
}
