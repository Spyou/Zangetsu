import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

// ── Pure helpers (tested) ─────────────────────────────────────────────────────

/// Returns a file name like `zangetsu-backup-20260702-0905.json`.
String backupFileName(DateTime now) {
  final y  = now.year.toString().padLeft(4, '0');
  final mo = now.month.toString().padLeft(2, '0');
  final d  = now.day.toString().padLeft(2, '0');
  final h  = now.hour.toString().padLeft(2, '0');
  final mi = now.minute.toString().padLeft(2, '0');
  return 'zangetsu-backup-$y$mo$d-$h$mi.json';
}

/// Decodes [raw] as JSON and asserts it is a JSON object.
/// Throws [FormatException] if the string is not valid JSON or not an object.
Map<String, dynamic> parseBackupJson(String raw) {
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    throw const FormatException('Backup file is not valid JSON');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Backup JSON must be a JSON object, not an array or primitive');
  }
  return decoded;
}

// ── Transport class ───────────────────────────────────────────────────────────

class BackupFile {
  /// Encodes [payload] as JSON and saves it into the public
  /// **Downloads/Zangetsu** folder so the user can find it in their file
  /// manager. Returns the saved public path, or `null` if the move to shared
  /// storage failed.
  Future<String?> export(
    Map<String, dynamic> payload, {
    bool keepLocalCopy = false,
  }) async {
    final name    = backupFileName(DateTime.now());
    final tmpDir  = await getTemporaryDirectory();
    final file    = File('${tmpDir.path}/$name');
    await file.writeAsString(jsonEncode(payload));

    // TV boxes usually have no document-picker UI, so restore-from-file can't
    // browse public Downloads. Keep an app-private, always-readable copy (no
    // storage permission needed) that [listLocalBackups] can enumerate. Only
    // done when the caller asks (TV) — phone exports are byte-identical.
    if (keepLocalCopy) {
      try {
        final dir = await _localBackupDir();
        if (dir != null) await file.copy('${dir.path}/$name');
      } catch (_) {/* best-effort — never block the primary export */}
    }

    return FileDownloader().moveFileToSharedStorage(
      file.path,
      SharedStorage.downloads,
      directory: 'Zangetsu',
    );
  }

  /// App-private, permission-free backups directory in external app storage.
  Future<Directory?> _localBackupDir() async {
    final ext = await getExternalStorageDirectory();
    if (ext == null) return null;
    final dir = Directory('${ext.path}/backups');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Backup files this app can read back without a document picker, newest
  /// first. Scans the app-private backups dir plus a best-effort look at the
  /// public Downloads/Zangetsu folder (readable on many TV boxes). Used by the
  /// TV restore flow in place of the (usually absent) system file picker.
  Future<List<File>> listLocalBackups() async {
    final found = <String, File>{}; // de-dupe by file name
    Future<void> scan(Directory? d) async {
      if (d == null || !d.existsSync()) return;
      try {
        for (final e in d.listSync()) {
          if (e is File && e.path.toLowerCase().endsWith('.json')) {
            found[e.uri.pathSegments.last] = e;
          }
        }
      } catch (_) {/* unreadable dir (scoped storage) — skip */}
    }

    await scan(await _localBackupDir());
    await scan(Directory('/storage/emulated/0/Download/Zangetsu'));

    final files = found.values.toList()
      ..sort((a, b) => b.path.compareTo(a.path)); // name embeds the timestamp
    return files;
  }

  /// Reads and parses a backup [file] chosen from [listLocalBackups].
  Future<Map<String, dynamic>> readBackup(File file) async =>
      parseBackupJson(await file.readAsString());

  /// Opens the system file picker (JSON filter), reads the chosen file, and
  /// returns the parsed map. Returns `null` if the user cancels.
  Future<Map<String, dynamic>?> import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null) return null;

    final picked = result.files.single;
    final String content;
    if (picked.path != null) {
      content = await File(picked.path!).readAsString();
    } else if (picked.bytes != null) {
      content = utf8.decode(picked.bytes!);
    } else {
      throw const FormatException('Could not read picked file — no path or bytes available');
    }
    return parseBackupJson(content);
  }
}
