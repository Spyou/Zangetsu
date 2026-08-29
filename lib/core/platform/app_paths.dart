import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'apple_tv.dart';

/// Writable app-private directory for durable-ish files (logs, staged fonts,
/// extension payloads, …).
///
/// iOS/macOS/Android use Application Support. Physical Apple TV cannot create
/// that directory (errno 1) — only Library/Caches and tmp are writable, so we
/// store under Caches instead. The tvOS simulator allows Application Support,
/// but using Caches on all Apple TV builds keeps device behavior consistent.
Future<Directory> getWritableAppDirectory() async {
  if (isAppleTv) {
    final cache = await getApplicationCacheDirectory();
    final dir = Directory('${cache.path}/app');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }
  return getApplicationSupportDirectory();
}

/// A named subdirectory under [getWritableAppDirectory], created if missing.
Future<Directory> writableAppSubdir(String name) async {
  final root = await getWritableAppDirectory();
  final dir = Directory('${root.path}/$name');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}
