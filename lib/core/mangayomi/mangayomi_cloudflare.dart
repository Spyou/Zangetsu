import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../mihon/mihon_extension_service.dart';
import '../provider/cf_solve_needed.dart';

class MangayomiCloudflare {
  static const MethodChannel _channel = MethodChannel('AniAura/mihon');

  static Future<void> solve(String url) async {
    if (!Platform.isIOS) {
      await MihonExtensionService.solveCloudflare(url);
      return;
    }

    try {
      await _channel.invokeMethod<void>('solveMangayomiCloudflare', {
        'url': url,
      });
      final host = Uri.tryParse(url)?.host;
      if (host != null && host.isNotEmpty) CfSolveNeeded.clear(host);
    } on PlatformException catch (error) {
      debugPrint('[mangayomi] Cloudflare solve failed: $error');
    } on MissingPluginException {
      debugPrint('[mangayomi] iOS Cloudflare solver is unavailable');
    }
  }
}
