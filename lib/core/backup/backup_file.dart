import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
  /// Encodes [payload] as JSON, writes it to a temp file, and opens the OS
  /// share sheet so the user can save it to Downloads, Drive, etc.
  Future<void> export(Map<String, dynamic> payload) async {
    final name    = backupFileName(DateTime.now());
    final tmpDir  = await getTemporaryDirectory();
    final file    = File('${tmpDir.path}/$name');
    await file.writeAsString(jsonEncode(payload));

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        fileNameOverrides: [name],
      ),
    );
  }

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
